#!/usr/bin/env python3
"""Deterministically generate the checked-in project. Not run during Xcode builds."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parents[1]
project = root / 'LumaPlayer.xcodeproj'
if (project / 'project.pbxproj').exists():
    raise SystemExit('Project already exists. Edit it in Xcode; regeneration would erase signing and local settings.')
project.mkdir(exist_ok=True)
def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return '"' + s.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n') + '"'
objects = []
def obj(name, body): objects.append(f'{ident(name)} = {{ {body} }};'); return ident(name)

sources = [
    'PlayerSystem/OnlineMovieMetadata.swift',
    'PlayerSystem/OnlineMovieViews.swift',
    'PlayerSystem/PlayQueueActions.swift',
    'PlayerSystem/PlayQueueView.swift',
    'PlayerSystem/BrowserDirectoryWatcher.swift',
    'PlayerSystem/SystemHDRPlayback.swift',
    'PlayerSystem/PlayerIdentity.swift',
    'PlayerSystem/QueueMetadataValue.swift',
    'PlayerSystem/MediaReadScheduling.swift',
    'PlayerSystem/MediaSystemServices.swift',
    'PlayerSystem/QueueMetadata.swift',
    'PlayerSystem/FileDialogs.swift',
    'PlayerSystem/LiveTextWindow.swift',
    'PlayerSystem/PlayerWindowLifecycle.swift',
    'PlayerSystem/PlaybackShortcutPolicy.swift',
    'PlayerSystem/PlayerKeyboardFocus.swift',
    'PlayerSystem/PlaybackPreferences.swift',
    'PlayerSystem/PlaybackPreferencesView.swift',
    'PlayerSystem/PlaybackGeometry.swift',
    'PlayerSystem/PlaybackGeometryView.swift',
    'PlayerSystem/FolderQueue.swift',
    'PlayerSystem/PlayerWindowModes.swift',
    'native/Player/Modern/IIVEPlayerApp.swift',
    'native/Player/Modern/PlayerModel.swift',
    'native/Player/Modern/PlayerView.swift',
    'native/Player/Modern/PlayerSettings.swift',
    'native/Player/Modern/PlayerActions.swift',
    'native/Player/Modern/PlaybackChrome.swift',
    'native/Player/Modern/VideoInformation.swift',
    'native/Player/Modern/MPVSession.m',
    'native/Player/Modern/LocalVideoPreview.m',
    'native/Player/VideoView.m'
]
headers = [
    'native/FSRCNNXMetal/Sources/FSRCNNXMetal/FSRCNNXModel.swift',
    'native/FSRCNNXMetal/Sources/FSRCNNXMetal/Bridge.swift',
    'native/FSRCNNXMetal/include/IIVEFSR.h',
    'native/Player/Modern/MPVSession.h',
    'native/Player/Modern/LocalVideoPreview.h',
    'native/Player/Modern/VideoCrop.h',
    'native/Player/Modern/Player-Bridging-Header.h',
    'native/Player/VideoView.h',
    'native/AppleBackend/AppleBackend.m',
    'native/AppleBackend/IIVEApple.h',
    'native/mpv-filter/vf_iive_apple.c',
    'native/mpv-filter/iive_surface.h',
    'native/mpv-filter/iive_surface.c',
    'native/mpv-filter/vf_iive_rife.c'
]
app_resources = [
    'AppIcon.icon',
    'Assets.xcassets',
    'AppIcon.icns',
    'Localizable.xcstrings',
    'InfoPlist.xcstrings'
]

refs=[]; builds=[]; resbuilds=[]

for name in sources + headers:
    typ = 'sourcecode.swift' if name.endswith('.swift') else 'sourcecode.c.objc' if name.endswith('.m') else 'sourcecode.c.h' if name.endswith('.h') else 'sourcecode.c.c'
    ref=obj(name, f'isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(name)}; sourceTree = SOURCE_ROOT;'); refs.append(ref)
    if name in sources: builds.append(obj('build:'+name, f'isa = PBXBuildFile; fileRef = {ref};'))

for name in app_resources:
    typ = 'folder.iconcomposer.icon' if name.endswith('.icon') else 'folder.assetcatalog' if name.endswith('.xcassets') else 'text.json.xcstrings' if name.endswith('.xcstrings') else 'image.icns'
    ref=obj(name, f'isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(name)}; sourceTree = SOURCE_ROOT;'); refs.append(ref)
    resbuilds.append(obj('build:'+name, f'isa = PBXBuildFile; fileRef = {ref};'))

product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = "Luma Player.app"; sourceTree = BUILT_PRODUCTS_DIR;')
group=obj('group',f'isa = PBXGroup; children = ({",".join(refs + [product])}); sourceTree = "<group>";')
srcphase=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)}); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
resphase=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resbuilds)}); runOnlyForDeploymentPostprocessing = 0;')

def script(name, script):
    return obj(name, f'isa = PBXShellScriptBuildPhase; name = {q(name)}; buildActionMask = 2147483647; alwaysOutOfDate = 1; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash; shellScript = {q(script)};')

deps=script('Build native engines', 'set -euo pipefail\ncd "$SRCROOT"\nmkdir -p build\nscripts/build-mpv.sh > "$SRCROOT/build/xcode-backends.log" 2>&1 || { tail -80 "$SRCROOT/build/xcode-backends.log"; exit 1; }\n')
resources_script=script('Bundle shader resources','set -euo pipefail\ncd "$SRCROOT"\npython3 scripts/player-resources.py "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"\n')

settings={
'ARCHS':'arm64','MACOSX_DEPLOYMENT_TARGET':'27.0','SDKROOT':'macosx','SWIFT_VERSION':'6.0',
'SWIFT_EMIT_LOC_STRINGS':'YES','LOCALIZATION_PREFERS_STRING_CATALOGS':'YES',
'CLANG_ENABLE_OBJC_ARC':'YES','CLANG_ENABLE_MODULES':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'NO',
'CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':'-','ENABLE_HARDENED_RUNTIME':'NO','PRODUCT_BUNDLE_IDENTIFIER':'com.august.lumaplayer',
'PRODUCT_NAME':'Luma Player','GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_KEY_CFBundleDisplayName':'Luma Player','INFOPLIST_KEY_LSApplicationCategoryType':'public.app-category.video',
'CURRENT_PROJECT_VERSION':'4','MARKETING_VERSION':'0.4.0',
'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
'INFOPLIST_KEY_CFBundleIconName':'AppIcon',
'INFOPLIST_KEY_CFBundleIconFile':'AppIcon',
'SWIFT_OBJC_BRIDGING_HEADER':'$(SRCROOT)/native/Player/Modern/Player-Bridging-Header.h',
'HEADER_SEARCH_PATHS':['$(SRCROOT)/native/Player','$(SRCROOT)/native/Player/Modern','$(SRCROOT)/.research/mpv-native/include'],
'LIBRARY_SEARCH_PATHS':['$(SRCROOT)/build/mpv','$(SRCROOT)/native/FSRCNNXMetal/.build/release'],
'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/build/mpv','$(SRCROOT)/build/apple','$(SRCROOT)/native/RIFEBackend/.build/release','$(SRCROOT)/native/FSRCNNXMetal/.build/release'],
'OTHER_LDFLAGS':['-lmpv','-framework','OpenGL','-framework','AppKit','-framework','VideoToolbox','-framework','CoreVideo','-framework','Metal','-framework','MetalPerformanceShaders','-framework','MetalPerformanceShadersGraph'],
'WARNING_CFLAGS':['-Wno-deprecated-declarations'],
'OTHER_SWIFT_FLAGS':['-Xcc','-Wno-deprecated-declarations'],
'GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS':'NO',
}

def config(name, debug):
    data=dict(settings); data.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if debug else '-O','GCC_OPTIMIZATION_LEVEL':'0' if debug else 's','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym'})
    if debug: data['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
    return obj(name,'isa = XCBuildConfiguration; name = '+('Debug' if debug else 'Release')+'; buildSettings = {'+''.join(f'{key} = '+('('+','.join(q(v) for v in value)+')' if isinstance(value,list) else q(value))+';' for key,value in data.items())+'};')

configs=[config('Debug',True),config('Release',False)]
cl=obj('configs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
pconfigs=[obj('project:'+n,f'isa = XCBuildConfiguration; name = {n}; buildSettings = {{}};') for n in ('Debug','Release')]
pcl=obj('projectconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(pconfigs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
target=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = ({deps},{srcphase},{frameworks},{resphase},{resources_script}); buildRules = (); dependencies = (); name = "LumaPlayer"; productName = "Luma Player"; productReference = {product}; productType = "com.apple.product-type.application";')
proj=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; LastSwiftUpdateCheck = 2700; }}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,"zh-Hant-TW","zh-Hant","zh-Hant-HK","zh-Hans"); mainGroup = {group}; projectDirPath = ""; projectRoot = ""; targets = ({target});')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+proj+'; }\n')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Luma Player.app" BlueprintName="LumaPlayer" ReferencedContainer="container:LumaPlayer.xcodeproj"/>'
(schemes/'Luma Player.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
