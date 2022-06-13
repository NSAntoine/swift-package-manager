import PackageModel
import Basics

// This class helps track module aliases in a package graph and override
// upstream alises if needed
class ModuleAliasTracker {
    var aliasMap = [PackageIdentity: [String: [ModuleAliasModel]]]()
    var idToProductToAllTargets = [PackageIdentity: [String: [Target]]]()
    var productToDirectTargets = [String: [Target]]()
    var productToAllTargets = [String: [Target]]()
    var parentToChildProducts = [String: [String]]()
    var childToParentProducts = [String: [String]]()
    var parentToChildIDs = [PackageIdentity: [PackageIdentity]]()
    var childToParentID = [PackageIdentity: PackageIdentity]()

    init() {}
    func addTargetAliases(targets: [Target], package: PackageIdentity) throws {
        let targetDependencies = targets.map{$0.dependencies}.flatMap{$0}
        for dep in targetDependencies {
            if case let .product(productRef, _) = dep,
               let productPkg = productRef.package {
                let productPkgID = PackageIdentity.plain(productPkg)
                // Track dependency package ID chain
                addPackageIDChain(parent: package, child: productPkgID)
                if let aliasList = productRef.moduleAliases {
                    // Track aliases for this product
                    try addAliases(aliasList,
                                   productID: productRef.ID,
                                   productName: productRef.name,
                                   originPackage: productPkgID,
                                   consumingPackage: package)
                }
            }
        }
    }

    func addAliases(_ aliases: [String: String],
                    productID: String,
                    productName: String,
                    originPackage: PackageIdentity,
                    consumingPackage: PackageIdentity) throws {
        if let aliasDict = aliasMap[originPackage] {
            let existingAliases = aliasDict.values.flatMap{$0}.filter {  aliases.keys.contains($0.name) }
            for existingAlias in existingAliases {
                if let newAlias = aliases[existingAlias.name], newAlias != existingAlias.alias {
                    // Error if there are multiple different aliases specified for
                    // targets in this product
                    throw PackageGraphError.multipleModuleAliases(target: existingAlias.name, product: productName, package: originPackage.description, aliases: existingAliases.map{$0.alias} + [newAlias])
                }
            }
        }

        for (originalName, newName) in aliases {
            let model = ModuleAliasModel(name: originalName, alias: newName, originPackage: originPackage, consumingPackage: consumingPackage)
            aliasMap[originPackage, default: [:]][productID, default: []].append(model)
        }
    }

    func addPackageIDChain(parent: PackageIdentity,
                           child: PackageIdentity) {
        if parentToChildIDs[parent]?.contains(child) ?? false {
            // Already added
        } else {
            parentToChildIDs[parent, default: []].append(child)
            // Used to track the top-most level package
            childToParentID[child] = parent
        }
    }

    // This func should be called once per product
    func trackTargetsPerProduct(product: Product,
                                package: PackageIdentity) {
        let targetDeps = product.targets.map{$0.dependencies}.flatMap{$0}
        var allTargetDeps = product.targets.map{$0.dependentTargets().map{$0.dependencies}}.flatMap{$0}.flatMap{$0}
        allTargetDeps.append(contentsOf: targetDeps)
        for dep in allTargetDeps {
            if case let .product(depRef, _) = dep {
                childToParentProducts[depRef.ID, default: []].append(product.ID)
                parentToChildProducts[product.ID, default: []].append(depRef.ID)
            }
        }

        var allTargetsInProduct = targetDeps.compactMap{$0.target}
        allTargetsInProduct.append(contentsOf: product.targets)
        idToProductToAllTargets[package, default: [:]][product.ID] = allTargetsInProduct
        productToDirectTargets[product.ID] = product.targets
        productToAllTargets[product.ID] = allTargetsInProduct
    }

    func validateAndApplyAliases(product: Product,
                                 package: PackageIdentity) throws {
        guard let targets = idToProductToAllTargets[package]?[product.ID] else { return }
        let targetsWithAliases = targets.filter{ $0.moduleAliases != nil }
        for target in targetsWithAliases {
            if target.sources.containsNonSwiftFiles {
                throw PackageGraphError.invalidSourcesForModuleAliasing(target: target.name, product: product.name, package: package.description)
            }
            target.applyAlias()
        }
    }

    func propagateAliases(observabilityScope: ObservabilityScope) {
        // First get the root package ID
        var pkgID = childToParentID.first?.key
        var rootPkg = pkgID
        while pkgID != nil {
            rootPkg = pkgID
            // pkgID is not nil here so can be force unwrapped
            pkgID = childToParentID[pkgID!]
        }
        guard let rootPkg = rootPkg else { return }
        // Propagate and override upstream aliases if needed
        var aliasBuffer = [String: ModuleAliasModel]()
        propagate(package: rootPkg, aliasBuffer: &aliasBuffer)

        // Now merge overriden upstream aliases and add them to
        // downstream targets
        if let productToAllTargets = idToProductToAllTargets[rootPkg] {
            for productID in productToAllTargets.keys {
                mergeAliases(productID: productID, observabilityScope: observabilityScope)
            }
        }
    }

    // Traverse upstream and override aliases for the same targets if needed
    func propagate(package: PackageIdentity, aliasBuffer: inout [String: ModuleAliasModel]) {
        if let curProductToTargetAliases = aliasMap[package] {
            let curAliasModels = curProductToTargetAliases.map {$0.value}.filter{!$0.isEmpty}.flatMap{$0}
            for aliasModel in curAliasModels {
                // A buffer is used to track the most downstream aliases
                // (hence the nil check here) to allow overriding upstream
                // aliases for targets; if the downstream aliases are applied
                // to upstream targets, then they get removed
                if aliasBuffer[aliasModel.name] == nil {
                    // First look up if there's an alias to be overriden,
                    // e.g. upstream has `moduleAliases: [Utils: FooUtils]`,
                    // and downstream has `moduleAliases: [FooUtils: BarUtils]`,
                    // then we want to add [Utils: BarUtils] to the buffer
                    // to track. Both [Utils: FooUtils] and [FooUtils: BarUtils]
                    // are also added to the buffer.
                    var next = aliasModel.alias
                    while let nextValue = aliasBuffer[next] {
                        next = nextValue.alias
                    }
                    if next != aliasModel.alias {
                        let chainedModel = ModuleAliasModel(name: aliasModel.name, alias: next, originPackage: aliasModel.originPackage, consumingPackage: aliasModel.consumingPackage)
                        aliasBuffer[aliasModel.name] = chainedModel
                    } else {
                        aliasBuffer[aliasModel.name] = aliasModel
                    }
                }
            }
        }
        if let curProductToTargets = idToProductToAllTargets[package] {
            // Check if targets for the products in this package have
            // aliases tracked by the buffer
            let curProductToTargetsToAlias = curProductToTargets.filter { $0.value.contains { aliasBuffer[$0.name] != nil } }
            if !curProductToTargetsToAlias.isEmpty {
                var usedKeys = Set<String>()
                for (curProductName, targetsForCurProduct) in curProductToTargets {
                    if let targetListToAlias = curProductToTargetsToAlias[curProductName] {
                        for targetToAlias in targetListToAlias {
                            if let aliasModel = aliasBuffer[targetToAlias.name] {
                                var didAlias = false
                                for curTarget in targetsForCurProduct {
                                    // Check if curTarget is relevant for aliasing
                                    let canAliasTarget = curTarget.name == aliasModel.name || curTarget.dependencies.contains { $0.name == aliasModel.name }
                                    if canAliasTarget {
                                        curTarget.addModuleAlias(for: aliasModel.name, as: aliasModel.alias)
                                        didAlias = true
                                    }
                                    // Check if curTarget needs pre-chained aliases
                                    // from its dependency products.
                                    let depProductAliases = curTarget.dependencies.compactMap{$0.product?.moduleAliases}.flatMap{$0}
                                    let depAliasesWithDuplicateKeys = depProductAliases.filter{$0.key == aliasModel.name}
                                    let usePreChainedAliases = (didAlias && !depAliasesWithDuplicateKeys.isEmpty) ||  depAliasesWithDuplicateKeys.count > 1

                                    if usePreChainedAliases {
                                        for depAlias in depProductAliases {
                                            if let preChainedAlias = aliasBuffer[depAlias.value] {
                                                curTarget.addModuleAlias(for: preChainedAlias.name, as: preChainedAlias.alias)
                                            }
                                        }
                                    }
                                }
                                if didAlias {
                                    usedKeys.insert(targetToAlias.name)
                                }
                            }
                        }
                    }
                }
                for used in usedKeys {
                    // Remove an entry for a used alias
                    aliasBuffer.removeValue(forKey: used)
                }
            }
        }
        guard let children = parentToChildIDs[package] else {
            aliasBuffer.removeAll()
            return
        }
        for childID in children {
            propagate(package: childID, aliasBuffer: &aliasBuffer)
        }
    }

    // Merge overriden upstream aliases and add them to downstream targets
    func mergeAliases(productID: String, observabilityScope: ObservabilityScope) {
        guard let childProducts = parentToChildProducts[productID] else { return }
        for child in childProducts {
            mergeAliases(productID: child, observabilityScope: observabilityScope)
            // Filter out targets in the current product with names that are
            // aliased with different values in the child products since they
            // should either not be aliased or their existing aliases if any
            // should not be overridden.
            let allTargetNamesInCurProduct = productToAllTargets[productID]?.compactMap{$0.name} ?? []
            let childTargetsAliases = productToDirectTargets[child]?.compactMap{$0.moduleAliases}.flatMap{$0}.filter{ !allTargetNamesInCurProduct.contains($0.key) }

            if let childTargetsAliases = childTargetsAliases,
               let directTargets = productToDirectTargets[productID] {
                // Keep track of all targets in this product that directly
                // or indirectly depend on the child product
                let directRelevantTargets = directTargets.filter {$0.dependsOn(productID: child)}
                var relevantTargets = directTargets.map{$0.dependentTargets()}.flatMap{$0}.filter {$0.dependsOn(productID: child)}
                relevantTargets.append(contentsOf: directTargets)
                relevantTargets.append(contentsOf: directRelevantTargets)
                let relevantTargetSet = Set(relevantTargets)
                // Used to compare with aliases defined in other child products
                // and detect a conflict if any.
                let allTargetsInOtherChildProducts = childProducts.filter{$0 != child }.compactMap{productToAllTargets[$0]}.flatMap{$0}
                let allTargetNamesInCurChildProduct = productToAllTargets[child]?.map{$0.name} ?? []
                for curTarget in relevantTargetSet {
                    for (nameToBeAliased, aliasInCurChild) in childTargetsAliases {
                        // Look up targets in other child products that have the
                        // name `nameToBeAliased` but are aliased with values
                        // conflicting with `aliasInCurChild`
                        let aliasesForTargetsRenamedInOtherChildProducts = allTargetsInOtherChildProducts.filter{$0.name == nameToBeAliased}.compactMap{$0.moduleAliases}.flatMap{$0}.filter{$0.key == nameToBeAliased}
                        let hasConflictingAliasesForTargetsRenamed = aliasesForTargetsRenamedInOtherChildProducts.contains { $0.value != aliasInCurChild }

                        if hasConflictingAliasesForTargetsRenamed {
                            // If conflicting aliases are found, wait until
                            // all conflicts are found and deleted (in the last
                            // `else` case), so do nothing for now.
                        } else if !aliasesForTargetsRenamedInOtherChildProducts.isEmpty,
                                  !allTargetNamesInCurChildProduct.contains(curTarget.name) {
                            for (aliasKey, aliasValue) in aliasesForTargetsRenamedInOtherChildProducts {
                                // Reset the old alias value with this aliasValue
                                if curTarget.moduleAliases?[aliasKey] != aliasValue {
                                    curTarget.addModuleAlias(for: aliasKey, as: aliasValue)
                                }
                            }
                        } else {
                            // If there are no aliases or conflicting aliases
                            // for the same key defined in other child products,
                            // those aliases should be removed from this target.
                            let targetsWithConflictingAliases = allTargetsInOtherChildProducts.filter { otherTarget in
                                if let otherAlias = otherTarget.moduleAliases?[nameToBeAliased] {
                                    return otherAlias != aliasInCurChild
                                } else {
                                    return otherTarget.name == nameToBeAliased
                                }
                            }

                            if !targetsWithConflictingAliases.isEmpty {
                                // If there are conflicting aliases, remove them
                                // and show a diag message
                                let conflictingAliases = targetsWithConflictingAliases.compactMap { $0.moduleAliases?[nameToBeAliased] }
                                var message = conflictingAliases.isEmpty ? "Targets named '\(nameToBeAliased)' found in other dependency products;" : "Conflicting module aliases found \(conflictingAliases + [aliasInCurChild]) for '\(nameToBeAliased)'; "
                                message += "these will be removed from target '\(curTarget.name)'"
                                observabilityScope.emit(info: message)

                                curTarget.removeModuleAlias(for: nameToBeAliased)
                            } else if curTarget.name != nameToBeAliased {
                                // Targets to be renamed already have aliases, so
                                // process their depending targets here
                                if curTarget.moduleAliases?[nameToBeAliased] == nil {
                                    // Remove any pre-chained aliases, i.e. value
                                    // of a module alias defined upstream that's used
                                    // as a key downstream
                                    let preChainedAliases = curTarget.moduleAliases?.filter{$0.value == aliasInCurChild} ?? [:]
                                    for preChainedAlias in preChainedAliases {
                                        if preChainedAlias.key != nameToBeAliased {
                                            curTarget.removeModuleAlias(for: preChainedAlias.key)
                                        }
                                    }
                                    curTarget.addModuleAlias(for: nameToBeAliased, as: aliasInCurChild)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// Used to keep track of module alias info for each package
class ModuleAliasModel {
    let name: String
    var alias: String
    let originPackage: PackageIdentity
    let consumingPackage: PackageIdentity

    init(name: String, alias: String, originPackage: PackageIdentity, consumingPackage: PackageIdentity) {
        self.name = name
        self.alias = alias
        self.originPackage = originPackage
        self.consumingPackage = consumingPackage
    }
}

extension Target {
    func dependsOn(productID: String) -> Bool {
        return dependencies.contains { dep in
            if case let .product(prodRef, _) = dep {
                return prodRef.ID == productID
            }
            return false
        }
    }

    func dependentTargets() -> [Target] {
        return dependencies.compactMap{$0.target}
    }
}

