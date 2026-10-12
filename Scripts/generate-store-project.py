#!/usr/bin/env python3
"""Generate a dependency-free Xcode project with explicit Store source membership."""
from pathlib import Path
import hashlib
import json
import plistlib
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
directory = root / 'AppStore'
project_dir = directory / 'LocalDictationStore.xcodeproj'
project_dir.mkdir(parents=True, exist_ok=True)
objects = {}

def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(label, isa, **fields):
    key = uid(label); objects[key] = dict(isa=isa, **fields); return key
def ref(path, kind): return obj('file:' + path, 'PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')
def build(label, file, **fields): return obj('build:' + label, 'PBXBuildFile', fileRef=file, **fields)
def phase(label, isa, files, **fields): return obj(label, isa, buildActionMask='2147483647', files=files, runOnlyForDeploymentPostprocessing='0', **fields)

core_files = sorted(root.glob('Sources/DictationCore/*.swift'))
shared_names = ['AudioRecorder', 'AudioInputProvider', 'WhisperTranscriber', 'LocalCorrectionService', 'CleanupClient',
                'CleanupCoordinator', 'RuntimePaths', 'ModelStore', 'DictationPreferences', 'VocabularyPreferences']
app_files = [directory / name for name in ['StoreAppMain.swift', 'StoreModelDownloader.swift']]
app_files += [root / 'Sources/LocalDictation' / (name + '.swift') for name in shared_names]
source_refs = []
def source_phase(label, files):
    builds = []
    for path in files:
        relative = '../' + str(path.relative_to(root))
        file = ref(relative, 'sourcecode.swift'); source_refs.append(file); builds.append(build(label + relative, file))
    return phase(label + 'Sources', 'PBXSourcesBuildPhase', builds)

core_product = obj('CoreProduct', 'PBXFileReference', explicitFileType='wrapper.framework', path='DictationCore.framework', sourceTree='BUILT_PRODUCTS_DIR')
app_product = obj('AppProduct', 'PBXFileReference', explicitFileType='wrapper.application', path='Local Dictation.app', sourceTree='BUILT_PRODUCTS_DIR')
product_group = obj('Products', 'PBXGroup', children=[app_product, core_product], name='Products', sourceTree='<group>')
core_sources = source_phase('Core', core_files); app_sources = source_phase('App', app_files)
resources = []
for path, kind in [('Assets.xcassets', 'folder.assetcatalog'), ('../Resources/ModelManifest.json', 'text.json'),
                   ('../THIRD_PARTY_NOTICES.txt', 'text'), ('../Licenses', 'folder'), ('PrivacyInfo.xcprivacy', 'text.xml')]:
    file = ref(path, kind); source_refs.append(file); resources.append(build('resource:' + path, file))
core_privacy = ref('CoreResources/PrivacyInfo.xcprivacy', 'text.xml'); source_refs.append(core_privacy)
core_resources = phase('CoreResources', 'PBXResourcesBuildPhase', [build('coreprivacy', core_privacy)])
app_resources = phase('AppResources', 'PBXResourcesBuildPhase', resources)
app_frameworks = phase('AppFrameworks', 'PBXFrameworksBuildPhase', [build('linkcore', core_product)])
core_frameworks = phase('CoreFrameworks', 'PBXFrameworksBuildPhase', [])
embed = phase('EmbedFrameworks', 'PBXCopyFilesBuildPhase', [build('embedcore', core_product, settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']})], dstPath='', dstSubfolderSpec='10', name='Embed Frameworks')
runtime = phase('EmbedRuntime', 'PBXShellScriptBuildPhase', [], name='Embed sandboxed speech helpers',
    shellPath='/bin/sh', alwaysOutOfDate='1', inputPaths=[], outputPaths=[],
    shellScript='python3 "${SRCROOT}/../Scripts/embed-store-runtime.py" --runtime "${LOCAL_DICTATION_STORE_RUNTIME_DIR}" --destination "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers" --identity "${EXPANDED_CODE_SIGN_IDENTITY:--}"\n')
common = {'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SDKROOT': 'macosx', 'ARCHS': 'arm64', 'ONLY_ACTIVE_ARCH': 'YES',
          'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES', 'DEVELOPMENT_TEAM': '2563R7W8T6',
          'CODE_SIGN_STYLE': 'Automatic', 'ENABLE_HARDENED_RUNTIME': 'YES', 'ENABLE_DEBUG_DYLIB': 'NO', 'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym'}
def configurations(label, settings):
    configs = []
    for configuration in ['Debug', 'Release']:
        values = dict(common, **settings)
        values['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if configuration == 'Debug' else '-O'
        values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'APP_STORE DEBUG' if configuration == 'Debug' else 'APP_STORE'
        if label == 'App':
            values['PRODUCT_BUNDLE_IDENTIFIER'] = 'dev.yosef.localdictation.store.development' if configuration == 'Debug' else 'dev.yosef.localdictation'
            # Xcode archives with its managed development identity, then
            # re-signs for the Store during app-store-connect export.
            values['CODE_SIGN_IDENTITY'] = 'Apple Development'
            values['LOCAL_DICTATION_DISPLAY_NAME'] = 'Local Dictation Store Preview' if configuration == 'Debug' else 'Local Dictation'
        configs.append(obj(label + configuration, 'XCBuildConfiguration', name=configuration, buildSettings=values))
    return obj(label + 'Configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
core_configs = configurations('Core', {'PRODUCT_NAME': 'DictationCore', 'PRODUCT_BUNDLE_IDENTIFIER': 'dev.yosef.localdictation.core',
    'DEFINES_MODULE': 'YES', 'GENERATE_INFOPLIST_FILE': 'YES', 'SKIP_INSTALL': 'YES', 'CURRENT_PROJECT_VERSION': '17',
    'MARKETING_VERSION': '2.3.0', 'DYLIB_INSTALL_NAME_BASE': '@rpath', 'INSTALL_PATH': '$(LOCAL_LIBRARY_DIR)/Frameworks'})
app_configs = configurations('App', {'PRODUCT_NAME': 'Local Dictation', 'INFOPLIST_FILE': 'Info.plist',
    'CODE_SIGN_ENTITLEMENTS': 'AppStore.entitlements', 'ENABLE_APP_SANDBOX': 'YES', 'ENABLE_USER_SCRIPT_SANDBOXING': 'NO',
    'CURRENT_PROJECT_VERSION': '17', 'MARKETING_VERSION': '2.3.0', 'SKIP_INSTALL': 'NO',
    'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks',
    'LOCAL_DICTATION_STORE_RUNTIME_DIR': '$(SRCROOT)/../.build-native/store-runtime'})
core_target = obj('CoreTarget', 'PBXNativeTarget', name='DictationCore', productName='DictationCore',
    productType='com.apple.product-type.framework', productReference=core_product, buildConfigurationList=core_configs,
    buildPhases=[core_sources, core_frameworks, core_resources], buildRules=[], dependencies=[])
proxy = obj('CoreProxy', 'PBXContainerItemProxy', containerPortal=uid('Project'), proxyType='1', remoteGlobalIDString=core_target, remoteInfo='DictationCore')
dependency = obj('CoreDependency', 'PBXTargetDependency', target=core_target, targetProxy=proxy)
app_target = obj('AppTarget', 'PBXNativeTarget', name='LocalDictationStore', productName='Local Dictation',
    productType='com.apple.product-type.application', productReference=app_product, buildConfigurationList=app_configs,
    buildPhases=[app_sources, app_frameworks, app_resources, embed, runtime], buildRules=[], dependencies=[dependency])
group = obj('MainGroup', 'PBXGroup', children=source_refs + [product_group], sourceTree='<group>')
project_configs = configurations('Project', {})
project = obj('Project', 'PBXProject', attributes={'LastUpgradeCheck': '2700', 'TargetAttributes': {app_target: {'DevelopmentTeam': '2563R7W8T6', 'ProvisioningStyle': 'Automatic'}}},
    buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en', 'Base'],
    mainGroup=group, productRefGroup=product_group, projectDirPath='', projectRoot='', targets=[app_target, core_target])
def encode(value, depth=0):
    indent = '\t' * depth
    if isinstance(value, dict): return '{\n' + ''.join('\t' * (depth + 1) + json.dumps(key) + ' = ' + encode(item, depth + 1) + ';\n' for key, item in value.items()) + indent + '}'
    if isinstance(value, list): return '(\n' + ''.join('\t' * (depth + 1) + encode(item, depth + 1) + ',\n' for item in value) + indent + ')'
    return json.dumps(value)
(project_dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + encode({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project}) + '\n')
scheme = ET.Element('Scheme', LastUpgradeVersion='2700', version='1.3')
action = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
entries = ET.SubElement(action, 'BuildActionEntries')
entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES', buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES')
def buildable(parent): ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=app_target, BuildableName='Local Dictation.app', BlueprintName='LocalDictationStore', ReferencedContainer='container:LocalDictationStore.xcodeproj')
buildable(entry)
launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', allowLocationSimulation='NO')
buildable(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'))
ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug'); ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
scheme_dir = project_dir / 'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True, exist_ok=True)
ET.indent(scheme); ET.ElementTree(scheme).write(scheme_dir / 'LocalDictationStore.xcscheme', encoding='utf-8', xml_declaration=True)

info = {'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleName': '$(PRODUCT_NAME)', 'CFBundleDisplayName': '$(LOCAL_DICTATION_DISPLAY_NAME)', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
    'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': '$(MACOSX_DEPLOYMENT_TARGET)', 'LSApplicationCategoryType': 'public.app-category.productivity',
    'NSMicrophoneUsageDescription': 'Local Dictation uses your microphone only when you start dictation or a microphone test. Speech is processed on this Mac.',
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}, 'LSMultipleInstancesProhibited': True,
    'NSHumanReadableCopyright': 'Copyright © 2026 Yosef Shammout',
    'NSServices': [{'NSMenuItem': {'default': 'Dictate with Local Dictation'}, 'NSMessage': 'dictateText',
        'NSPortName': '$(PRODUCT_NAME)', 'NSReturnTypes': ['NSStringPboardType'], 'NSRequiredContext': {},
        'NSRestricted': False, 'NSTimeout': '600000'}]}
with (directory / 'Info.plist').open('wb') as stream: plistlib.dump(info, stream)
for name, values in [('AppStore.entitlements', {'com.apple.security.app-sandbox': True, 'com.apple.security.device.audio-input': True,
                       'com.apple.security.network.client': True, 'com.apple.security.network.server': True}),
                     ('Helper.entitlements', {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})]:
    with (directory / name).open('wb') as stream: plistlib.dump(values, stream)
categories = [('FileTimestamp', 'C617.1'), ('SystemBootTime', '35F9.1'), ('DiskSpace', 'E174.1'), ('UserDefaults', 'CA92.1')]
for name, reasons in [('PrivacyInfo.xcprivacy', categories), ('CoreResources/PrivacyInfo.xcprivacy', [('SystemBootTime', '35F9.1')])]:
    privacy = {'NSPrivacyTracking': False, 'NSPrivacyTrackingDomains': [], 'NSPrivacyCollectedDataTypes': [],
               'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategory' + category,
                    'NSPrivacyAccessedAPITypeReasons': [reason]} for category, reason in reasons]}
    (directory / name).parent.mkdir(parents=True, exist_ok=True)
    with (directory / name).open('wb') as stream: plistlib.dump(privacy, stream)
print(project_dir)
