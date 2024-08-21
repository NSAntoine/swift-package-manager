//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "tsan_utils.h"

// Demonstration function to allow only ourApplicationsFile to be opened only if the process trying to open it
// is called ourApplication
static int policy_should_allow_open(kauth_cred_t cred, struct vnode *vp, struct label *label, int acc_mode) {
    const char *vnodeName = vnode_getname(vp); // Get the name of the file trying to be opened
    if (vnodeName && strcmp(vnodeName, "ourApplicationsFile") == 0) { // Check if this is the file we want to gatekeep
        char procName[MAXCOMLEN+1];
        proc_selfname(procName, sizeof(procName));

        if (strcmp(procName, "ourApplication") != 0) { // !!! this process is NOT called ourApplication !!! deny it and return EPERM
            vnode_putname(vnodeName); // release our reference
            return EPERM;
        }
    }

    vnode_putname(vnodeName); 
    return 0; // Sure, allow the file to be opened
}

static struct mac_policy_ops our_ops ={
    .mpo_vnode_check_open = policy_should_allow_open, 
};

static struct mac_policy_conf policy_configuration = {
    .mpc_name = "com.demo.protectFileDemo",
    .mpc_fullname = "Protect File Demo",

    .mpc_labelnames = NULL, // irrelevant field
    .mpc_labelname_count = 0, // irrelevant field

    .mpc_ops = &our_ops, // operations we want control over

    .mpc_loadtime_flags = MPC_LOADTIME_FLAG_UNLOADOK, // don't unload this policy

    .mpc_field_off = NULL, // irrelevant field
    .mpc_runtime_flags = 0 // this field is not to be set by us, but rather is set by the System when this policy is loaded
};

mac_policy_handle_t handle = 0;
int demoKextStart(kmod_info_t *ki, void *d) { // Entry point of Kext
    return mac_policy_register(&policy_configuration, &handle, d);
}
