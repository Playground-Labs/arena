#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .context
if ! xcodebuild -project Arena.xcodeproj -scheme Arena -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath .context/DerivedData -clonedSourcePackagesDirPath .context/XcodePackages \
    -jobs 4 CODE_SIGNING_ALLOWED=NO build > .context/xcode-build.log 2>&1; then
    tail -100 .context/xcode-build.log
    exit 1
fi
print 'ARENA BUILD PASSED'
print "$PWD/.context/DerivedData/Build/Products/Debug/Arena.app"
