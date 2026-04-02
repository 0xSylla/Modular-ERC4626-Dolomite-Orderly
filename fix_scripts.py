import re, os, sys

def fix_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    original = content

    # Find all getModule calls to identify which variables map to which module types
    getmodule_pattern = r'address\s+(\w+)\s*=\s*factory\.getModule\(keccak256\("([^"]+)"\)\);'
    module_vars = {}
    for match in re.finditer(getmodule_pattern, content):
        var_name = match.group(1)
        module_type = match.group(2)
        module_vars[var_name] = module_type

    # Replace address declarations with bytes32 declarations for factory.getModule vars
    for var_name, module_type in module_vars.items():
        pattern = rf'address\s+{re.escape(var_name)}\s*=\s*factory\.getModule\(keccak256\("{re.escape(module_type)}"\)\);'
        replacement = f'bytes32 {var_name} = keccak256("{module_type}");'
        content = re.sub(pattern, replacement, content)

    # Map of common local variable names to module types
    local_module_map = {
        'dolomiteModule': 'lending.dolomite',
        'kodiakModule': 'swap.kodiak',
        'orderlyModule': 'perps.orderly',
        'odosModule': 'swap.odos',
        'aaveModule': 'lending.aave',
        'morphoModule': 'lending.morpho',
    }

    # Replace vault.executeModule(address(varName), ...) patterns
    for var_name, module_type in local_module_map.items():
        hash_expr = f'keccak256("{module_type}")'
        # Various patterns
        content = re.sub(
            rf'(vault\.executeModule(?:\{{[^}}]*\}})?\()\s*\n\s+address\({re.escape(var_name)}\),',
            lambda m: m.group(1) + '\n            ' + hash_expr + ',',
            content
        )
        content = re.sub(
            rf'(vault\.executeModule(?:\{{[^}}]*\}})?\()address\({re.escape(var_name)}\),',
            lambda m: m.group(1) + hash_expr + ',',
            content
        )
        # Short form on same line: vA.executeModule(dolomiteModule, ...)
        content = re.sub(
            rf'(v[AB]\.executeModule\(){re.escape(var_name)},',
            lambda m: m.group(1) + hash_expr + ',',
            content
        )

    # Handle dolomiteModuleAddr variable
    for suffix in ['Addr', 'addr', 'Address']:
        for base, module_type in [('dolomiteModule', 'lending.dolomite'), ('kodiakModule', 'swap.kodiak'),
                                   ('orderlyModule', 'perps.orderly'), ('aaveModule', 'lending.aave'),
                                   ('morphoModule', 'lending.morpho')]:
            var_name = base + suffix
            hash_expr = f'keccak256("{module_type}")'
            content = re.sub(
                rf'vault\.executeModule\(\s*\n\s+{re.escape(var_name)},',
                f'vault.executeModule(\n            {hash_expr},',
                content
            )
            content = re.sub(
                rf'(router\.executeModule\(\s*\n\s+vaultAddr,\s*\n\s+){re.escape(var_name)},',
                rf'\g<1>{hash_expr},',
                content
            )

    # Handle AAVE_MODULE constant in TestAaveE2E.s.sol
    content = re.sub(
        r'v\.executeModule\(AAVE_MODULE,',
        'v.executeModule(keccak256("lending.aave"),',
        content
    )

    # Handle morphoModule variable from env in TestMorphoE2E
    content = re.sub(
        r'vault\.executeModule\(morphoModule,',
        'vault.executeModule(keccak256("lending.morpho"),',
        content
    )

    # address[] memory modules -> bytes32[] memory moduleTypes
    content = re.sub(
        r'address\[\]\s+memory\s+modules\s*=\s*new\s+address\[\]\(',
        'bytes32[] memory moduleTypes = new bytes32[](',
        content
    )
    content = re.sub(
        r'address\[\]\s+memory\s+modules',
        'bytes32[] memory moduleTypes',
        content
    )

    # Replace modules[N] = someAddr with moduleTypes[N] = hash
    all_module_map = {**local_module_map, **module_vars}
    for var_name, module_type in all_module_map.items():
        hash_expr = f'keccak256("{module_type}")'
        for i in range(10):
            content = content.replace(f'modules[{i}] = {var_name};', f'moduleTypes[{i}] = {hash_expr};')
            content = content.replace(f'modules[{i}] = address({var_name});', f'moduleTypes[{i}] = {hash_expr};')

    # Replace executeBatch, executeOpeningRequest, executeClosingRequest with moduleTypes
    content = content.replace('vault.executeBatch(modules, datas)', 'vault.executeBatch(moduleTypes, datas)')
    content = content.replace('router.executeBatch(vaultAddr, modules, datas)', 'router.executeBatch(vaultAddr, moduleTypes, datas)')
    content = re.sub(
        r'router\.executeOpeningRequest(\{[^}]*\})?\(vaultAddr,\s*0,\s*modules,\s*datas\)',
        lambda m: f'router.executeOpeningRequest{m.group(1) or ""}(vaultAddr, 0, moduleTypes, datas)',
        content
    )
    content = content.replace('router.executeClosingRequest(vaultAddr, 0, modules, datas)',
                              'router.executeClosingRequest(vaultAddr, 0, moduleTypes, datas)')

    # router.executeModule with address(newModule) or address(someModule)
    for var_name, module_type in local_module_map.items():
        hash_expr = f'keccak256("{module_type}")'
        content = re.sub(
            rf'(router\.executeModule\(\s*\n\s+vaultAddr,\s*\n\s+)address\({re.escape(var_name)}\),',
            rf'\g<1>{hash_expr},',
            content
        )
        # router.executeModule(\n  vaultAddr,\n  varName, (the var was changed to bytes32 already)
        # But some scripts have the var from getModule and it's now bytes32 - those should be fine

    # For RedeployArbModule: address(newModule) where newModule is DolomiteArbModule
    content = re.sub(
        r'((?:router|VaultCuratorRouter\([^)]+\))\.executeModule\(\s*\n\s+vaultAddr,\s*\n\s+)address\(newModule\),',
        r'\g<1>keccak256("lending.dolomite"),',
        content
    )

    # RecoverVault.s.sol: factory.emergencyExecute with KODIAK_MODULE
    content = re.sub(
        r'factory\.emergencyExecute\(\s*\n\s+VAULT,\s*\n\s+KODIAK_MODULE,',
        'factory.emergencyExecute(\n            VAULT,\n            keccak256("swap.kodiak"),',
        content
    )

    # E2EDualDolomiteTest: _bootstrapVault function signature
    content = content.replace(
        'function _bootstrapVault(DiracVault vault, address dolomiteModule,',
        'function _bootstrapVault(DiracVault vault, bytes32 dolomiteModule,'
    )

    # Fix router.executeModule calls that use module vars from getModule (now bytes32)
    # These should already work since we changed the type. But handle compact forms:
    for var_name, module_type in all_module_map.items():
        hash_expr = f'keccak256("{module_type}")'
        # router.executeModule(\n vaultAddr, varName, ...) - after bytes32 change, the var works
        # But for router.executeModule(vaultAddr, odosModule, ...) on one line:
        content = re.sub(
            rf'(router\.executeModule\(\s*\n\s+vaultAddr,\s+){re.escape(var_name)},',
            rf'\g<1>{hash_expr},',
            content
        )

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        return True
    return False

script_dir = os.path.join('C:\\Users\\DELL02\\Desktop\\DiracHoneypot\\script')
count = 0
for root, dirs, files in os.walk(script_dir):
    for fname in files:
        if fname.endswith('.sol'):
            fpath = os.path.join(root, fname)
            if fix_file(fpath):
                print(f"Fixed: {os.path.relpath(fpath, script_dir)}")
                count += 1

print(f"\nFixed {count} files")
