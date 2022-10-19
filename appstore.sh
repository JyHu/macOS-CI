#!/bin/bash

export LANG=en_US.UTF-8

set -e

###############################################
#### global inputs options

while getopts ":t:h" opt
do
    case $opt in
        t)
            # app target
            __INPUT_TARGET__=$OPTARG
            ;;
        h)
            echo "Automate packaging and upload to the App Store."
            echo ""
            echo "Usage: sh path/to/appstore.sh [options]"
            echo ""
            echo "Options:"
            echo "  -t  Buiding target, TigerTrade TigerTradeLite AllTarget"
            echo "  -h  Display usage and exit."
            echo ""
            exit 0;;
        ?)
            echo "unknown"
            exit -1;;
    esac
done

###############################################
#### help methods

# make a folder at ~/$1
function makeLocalFolder() {
    if [[ -d $1 ]]; then
        LOG "Duplicate directory exist and removed: $1"
        rm -rf $1
    fi

    LOG "Make directory at $1"
    mkdir -p $1
}

function LOG() {
    echo ">> $1"
}


###############################################
#### initial build space

# building folder
__BUILD_FOLDER__="build"
# tempory dsym cache folder
__ARCHIVE_DSYM_FOLDER__="archived_dSYMs"

makeLocalFolder $__ARCHIVE_DSYM_FOLDER__

###############################################
#### global build configs

__PROJ_FOLDER__=`pwd`
__SCRIPT_FOLDER__=$(cd "$(dirname "$0")"; pwd)
cd $__PROJ_FOLDER__

LOG "script path: $__SCRIPT_FOLDER__"
LOG "project path: $__PROJ_FOLDER__"

# 打包相关的配置文件
__PACK_OPTIONS_FILE__="$__SCRIPT_FOLDER__/package_options.plist"

function get_options() {
    tmp_param=`/usr/libexec/PlistBuddy -c "print $1" "$__PACK_OPTIONS_FILE__"`
    echo $tmp_param
}

# project name xxx.xcworkspace or xxx.xcodeproj
__PROJ_NAME__=$(get_options ":projname")
# apple id
__APPLE_ID__=$(get_options ":appleID")
#
__2FA_PASSWORD__=$(get_options ":password")
# app version
__APP_VER__=$(sed -n '/MARKETING_VERSION/{s/MARKETING_VERSION = //;s/;//;s/^[[:space:]]*//;p;q;}' `ls ./ | grep .*\.xcodeproj$`/project.pbxproj)
# app configuration
__CONFIGURATION__="AppStore"

echo ""
LOG "Package Options :" "$__PACK_OPTIONS_FILE__"
LOG "  Build Target  : $__INPUT_TARGET__"
LOG "  Project name  : $__PROJ_NAME__"
LOG "  APP Version   : $__APP_VER__"
LOG "  Apple ID      : $__APPLE_ID__"
LOG "  Configuration : $__CONFIGURATION__"
echo ""


LOG "update pod resources"
pod update

function build_package() {

    #-------------------------------------------------------------------------------------
    #----------  解析打包的参数
    # building target
    __BUILDING_TARGET__=$1
    # team id of provision profile
    __TEAM_ID__=$(get_options ":target:$1:config:$__CONFIGURATION__:teamid")
    # building scheme
    __SCHEME__=$(get_options ":target:$1:config:$__CONFIGURATION__:scheme")
    
    echo ""
    LOG "*********************************************************************************"
    LOG "*********************************************************************************"
    LOG ""
    LOG "Build with configs :"
    LOG "  Build Target     : $__BUILDING_TARGET__"
    LOG "  Configuration    : $__CONFIGURATION__"
    LOG "  Team ID          : $__TEAM_ID__"
    LOG "  Scheme           : $__SCHEME__"
    echo ""
    
    # make tempory build folder
    makeLocalFolder $__BUILD_FOLDER__
    
    LOG "Clean the project ..."
    xcodebuild clean -workspace $__PROJ_NAME__  \
        -scheme $__SCHEME__                     \
        -configuration $__CONFIGURATION__
        
    LOG "Archiving ..."
    xcodebuild archive -quiet                        \
        -workspace $__PROJ_NAME__                    \
        -scheme $__SCHEME__                          \
        -configuration $__CONFIGURATION__            \
        -archivePath "$__BUILD_FOLDER__/$__SCHEME__" \
        -destination generic/platform=macOS > /dev/null 2>&1

    __ARCHIVE_FILE__="$__BUILD_FOLDER__/$__SCHEME__.xcarchive"

    if [ ! -e "$__ARCHIVE_FILE__" ]; then
        LOG ".xcarchive doesn't exist";
        exit -1;
    fi
    
    __DSYM_FILE_NAME__=`ls "$__ARCHIVE_FILE__/dSYMs" | grep .*app\.dSYM`
    __DSYM_FILE_PATH__="$__ARCHIVE_FILE__/dSYMs/$__DSYM_FILE_NAME__"

    if [ ! -d "$__DSYM_FILE_PATH__" ]; then
        LOG "no dSYM file at $__DSYM_FILE_PATH__"
        exit -1
    fi


    LOG "dSYM file at $__ARCHIVE_FILE__" # .app.dSYM
    tmp_dSYMName="${__DSYM_FILE_NAME__/\.app\.dSYM/}_${__APP_VER__}_AppStore"
    cp -R "$__DSYM_FILE_PATH__" "$__ARCHIVE_DSYM_FOLDER__/$tmp_dSYMName.dSYM"
    
    __EXPORT_OPTIONS__="$__BUILD_FOLDER__/export_options.plist"
    cat > "$__EXPORT_OPTIONS__" <<- EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
    <key>method</key>
    <string>app-store</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$__TEAM_ID__</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
    
    LOG "export archive"
    # https://rderik.com/blog/exportoptions-properties/
    # 注意 allowProvisioningUpdates 参数，自动签名的时候需要用到，如果非自动签名是就不需要了。
    # 还有导出的参数配置，如果是自动签名的话，signingStyle 需要设置为 automatic；
    # 如果手动签名的话，配置文件里就需要 provisioningProfiles signingCertificate installerSigningCertificate 等参数
    xcodebuild -exportArchive -quiet \
        -archivePath $__ARCHIVE_FILE__ \
        -exportPath "$__BUILD_FOLDER__" \
        -exportOptionsPlist "$__EXPORT_OPTIONS__" \
        -allowProvisioningUpdates

    __PKG_FILE__="$__BUILD_FOLDER__/`ls $__BUILD_FOLDER__ | grep .*\.pkg$`"

    LOG "pkg file : $__PKG_FILE__"

    if [ ! -f "$__PKG_FILE__" ]; then
        LOG ".pkg doesn't exist";
        exit -1;
    fi
    
    LOG "validate ..."
    xcrun altool --validate-app --f "$__PKG_FILE__" -t macOS -u $__APPLE_ID__ -p $__2FA_PASSWORD__  > /dev/null 2>&1
    
    if [ $? -eq 1 ]; then
        LOG "altool validate-app fail"
        exit -1;
    fi

    LOG "altool validate-app success"


    LOG "upload app ..."
    xcrun altool --upload-app --f "$__PKG_FILE__" -t macOS -u $__APPLE_ID__ -p $__2FA_PASSWORD__ > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        LOG "altool --upload-app success"
    else
        LOG "altool --upload-app fail"
    fi
}

function build_all_target() {
    # find all valid targets
    __temp_targets=`/usr/libexec/PlistBuddy -c "Print :target" "$__PACK_OPTIONS_FILE__" | perl -lne 'print $1 if /^    (\S*) =/'`
    for element in ${__temp_targets[@]}
    do
        # find all valid configs of $element
        __temp_configs=`/usr/libexec/PlistBuddy -c "Print :target:$element:config" "$__PACK_OPTIONS_FILE__" | perl -lne 'print $1 if /^    (\S*) =/'`
        
        if [[ "${__temp_configs[@]}" =~ "$__CONFIGURATION__" ]]; then
            build_package $element
        else
            echo ""
            LOG "No $__CONFIGURATION__ configs of $element"
            echo ""
        fi
    done
}

#字符串不为空，长度不为0
if [ "$__INPUT_TARGET__" == "" ]; then
    build_all_target
else
    if [[ "$__INPUT_TARGET__" == "AllTarget" ]]; then
        build_all_target
    else
        build_package $__INPUT_TARGET__
    fi
fi


LOG "Processing ..."

if [ "`ls -A $__ARCHIVE_DSYM_FOLDER__`" == "" ]; then
    LOG "There is no dSYM files at $__ARCHIVE_DSYM_FOLDER__"
else
    # dSYM target
    DESTINATION_DSYM="Shared/Performance/dSYMs/${__APP_VER__}"
    
    if [ ! -d "/Users/`whoami`/$DESTINATION_DSYM" ]; then
        mkdir -p ~/$DESTINATION_DSYM
    fi

    LOG "Copy dSYMs ..."
    cp -rf ./$__ARCHIVE_DSYM_FOLDER__/* ~/$DESTINATION_DSYM

    echo "mark build as successed"
fi

LOG "ending..."
