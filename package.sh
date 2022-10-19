#!/bin/bash
#
#  package.sh
#  Stock-Mac
#
#  Created by Jo on 2022/6/8.
#  Copyright © 2022 . All rights reserved.
#
#

# jenkins里必须设置为utf8，否则会报错
export LANG=en_US.UTF-8

set -e


# 是否需要带有颜色的输出
# 在terminal为了查看方便，带颜色比较好，但是在jenkins里又显示不了颜色
__ATTRIBUTED_LOG__=false

while getopts ":c:ah" opt
do
    case $opt in
        a)
            # 是否带有颜色的输出日志
             __ATTRIBUTED_LOG__=true
            ;;
        c)
            # 打包类型，Release RC
            __INPUT_CONFIGURATION__=$OPTARG
            ;;
        h)
            echo " 执行打包公正流程"
            echo ""
            echo " 参数列表"
            echo "  -c configuration Release、RC，不可为空"
            echo "  -a attributed log，可为空，是否带有颜色的输出日志"
            echo ""
            echo "eg: sh path/to/package.sh -c Release -a"
            exit 0;;
        ?)
            echo "unknown"
            exit 1;;
    esac
done

if [[ "$__INPUT_CONFIGURATION__" == "" ]]; then
    LOG "请选择需要打包的环境，如 Release RC"
    exit -1
fi



#-------------------------------------------------------------------------------------
#----------  项目及编译相关信息的配置

# 输出日志
# $1 日志内容
# $2 命令内容，可为空，如果有值，会以带颜色的方式显示
function LOG() {
    if [[ $__ATTRIBUTED_LOG__ == true ]]; then
        printf "\e[1;97;41m>> \e[0\e[1;97;44m $(date "+%Y/%m/%d %H:%M:%S") \e[0m\e[97m $1 \e[92m$2 \e[33m\n"
    else
        printf "$1 $2\n"
    fi
}

# 以当前目录为根节点创建目录
function makeLocalFolder() {
    if [[ -d $1 ]]; then
        LOG "存在重复的目录并移除 $1"
        rm -rf $1
    fi

    LOG "创建目录 $1"
    mkdir -p $1
}


# 脚本执行的当前目录即是工程目录
__PROJECT_FOLDER__=`pwd`
# 因为脚本可以在任意位置，所以需要特殊去获取
__SCRIPT_FOLDER__=$(cd "$(dirname "$0")"; pwd)
# 定位到当前工程目录
cd $__PROJECT_FOLDER__

LOG "脚本目录：" $__SCRIPT_FOLDER__
LOG "工程目录：" $__PROJECT_FOLDER__

# dSYM文件的暂存目录
__ARCHIVE_DSYM_FOLDER__="archived_dSYMs"
# dmg文件的暂存目录
__ARCHIVE_DMG_FOLDER__="archived_dmgs"

# 创建需要的临时目录
makeLocalFolder $__ARCHIVE_DSYM_FOLDER__
makeLocalFolder $__ARCHIVE_DMG_FOLDER__

#-------------------------------------------------------------------------------------
#----------  编译、打包文件的存放目录

# 在这个目录下面查找 archive 包
__BUILD_PATH__="./build"

# 删除build目录下的所有文件，防止有之前内容残留
makeLocalFolder $__BUILD_PATH__

# 打包相关的配置文件
__PACK_OPTIONS_FILE__="$__SCRIPT_FOLDER__/package_options.plist"

function get_options() {
    tmp_param=`/usr/libexec/PlistBuddy -c "print $1" "$__PACK_OPTIONS_FILE__"`
    echo $tmp_param
}

# 工程名 xxx.xcworkspace
__PROJ_NAME__=$(get_options ":projname")
# 电脑解锁密码，用于解锁钥匙串
__MAC_PWD__=$(get_options ":macpwd")
# apple id
__APPLE_ID__=$(get_options ":appleID")
# https://support.apple.com/zh-cn/HT204397
__2FA_PASSWORD__=$(get_options ":password")
# 当前打包的版本号，因为直接从 info.plist 中获取，会是一个静态常量，所以可以从任意一个target的工程文件中读取
__APP_VER__=$(sed -n '/MARKETING_VERSION/{s/MARKETING_VERSION = //;s/;//;s/^[[:space:]]*//;p;q;}' `ls ./ | grep .*\.xcodeproj$`/project.pbxproj)


LOG "Package Options : $__PACK_OPTIONS_FILE__"
LOG "  Project name  : $__PROJ_NAME__"
LOG "  Mac password  : $__MAC_PWD__"
LOG "  APP Version   : $__APP_VER__"
LOG "  Apple ID      : $__APPLE_ID__"

#-------------------------------------------------------------------------------------
#----------  代码、资源更新操作，更新代码

LOG "更新pod资源 ..."
pod update

# 执行打包、公正操作
# param 1 target
function build_package() {
    #-------------------------------------------------------------------------------------
    #----------  解析打包的参数
    # 打包taregt
    __BUILDING_TARGET__=$1
    # 当前打包项目对应target的bundle id
    __BUNDLE_ID__=$(get_options ":target:$1:bundleid")
    # 获取dmg显示名字
    __DMG_CONFIG_NAME__=$(get_options ":target:$1:dmgName")
    # 获取dmg文件名称
    __DMG_CONFIG_FILE_NAME__=$(get_options ":target:$1:dmgFileName")
    # 签名证书，如 Developer ID Application: xxxx Pte Ltd (322Yxxxxxxx)
    __BUILDING_CERT__=$(get_options ":target:$1:config:$__INPUT_CONFIGURATION__:cert")
    # 团队的id，签名证书后面括号里的内容
    __TEAM_ID__=$(get_options ":target:$1:config:$__INPUT_CONFIGURATION__:teamid")
    # 用于打包的scheme
    __SCHEME__=$(get_options ":target:$1:config:$__INPUT_CONFIGURATION__:scheme")
    # entitlements
    __ENTITLEMENTS__=$(get_options ":target:$1:entitlements")
    # current build working path
    __WORKING_PATH__="$__BUILD_PATH__/$__SCHEME__"
    
    echo ""
    LOG "*********************************************************************************"
    LOG " **********************                                   **********************"
    LOG "*********************************************************************************"
    LOG ""
    LOG "Build with configs :"
    LOG "  Build Target     : $__BUILDING_TARGET__"
    LOG "  Configuration    : $__INPUT_CONFIGURATION__"
    LOG "  Bundle ID        : $__BUNDLE_ID__"
    LOG "  Certficate       : $__BUILDING_CERT__"
    LOG "  Team ID          : $__TEAM_ID__"
    LOG "  Scheme           : $__SCHEME__"
    LOG "  DMG name         : $__DMG_CONFIG_NAME__"
    LOG "  Entitlements     : $__ENTITLEMENTS__"
    echo ""
    
    #-------------------------------------------------------------------------------------
    #----------  编译工程
    
    # https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/resolving_common_notarization_issues#3087731
    # Avoid the get-task-allow entitlement
    # 将entitlements中的这个属性设置为false
    # 但是需要注意的是，在正常的开发过程中，这个值必须保持为true
    /usr/libexec/PlistBuddy -c "set com.apple.security.get-task-allow 0" "./$__ENTITLEMENTS__"
    
    # 创建打包目录，每个scheme单独创建
    mkdir -p $__BUILD_PATH__/$__SCHEME__

    if [[ "$__INPUT_CONFIGURATION__" == "RC" ]]; then
        # 我们项目早期定义的scheme就是Beta，但是发版什么又叫RC，所以特别处理一下
        __XCCONFIGURATION__="Beta"
    else
        __XCCONFIGURATION__="Release"
    fi

    # 清理资源
    LOG "清理项目资源 ..." "xcodebuild clean -workspace $__PROJ_NAME__ -scheme $__SCHEME__ -configuration $__XCCONFIGURATION__"
    xcodebuild clean -workspace $__PROJ_NAME__  \
        -scheme $__SCHEME__                     \
        -configuration $__XCCONFIGURATION__

    # 编译项目
    LOG "编译项目" "xcodebuild archive -quiet -workspace $__PROJ_NAME__ -scheme $__SCHEME__ -configuration $__XCCONFIGURATION__ -archivePath $__WORKING_PATH__/$__SCHEME__ -destination generic/platform=macOS"
    xcodebuild archive -quiet                       \
        -workspace $__PROJ_NAME__                   \
        -scheme $__SCHEME__                         \
        -configuration $__XCCONFIGURATION__         \
        -archivePath $__WORKING_PATH__/$__SCHEME__  \
        -destination generic/platform=macOS
    
    LOG "编译完成 (Target: $1, Configuration: $__INPUT_CONFIGURATION__)"

    #-------------------------------------------------------------------------------------
    #----------  查找编译文件，如果编译成功了就继续，否则退出后续操作

    # 查找 archive 包
    __ARCHIVE_FILE_PATH__="$__WORKING_PATH__/$__SCHEME__.xcarchive"

    # 如果没有archive文件，那么就直接退出
    if [ ! -d $__ARCHIVE_FILE_PATH__ ]; then
        LOG "没有找到打包后的归档文件：" "$__ARCHIVE_FILE_PATH__"
        exit -1
    fi
    
    LOG "打包后的归档文件：" "$__ARCHIVE_FILE_PATH__"
    
    # 导出app的信息
    __EXPORT_OPTIONS_PLIST__="$__BUILD_PATH__/$__SCHEME__/exportOptions.plist"
    
    cat > "$__EXPORT_OPTIONS_PLIST__" <<- EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>developer-id</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>${__TEAM_ID__}</string>
</dict>
</plist>
EOF

    LOG "写入导出配置参数：" "$__EXPORT_OPTIONS_PLIST__"
    cat $__EXPORT_OPTIONS_PLIST__
    
    # 导出打包的app
    LOG "导出app文件：" "xcodebuild -exportArchive -archivePath $__ARCHIVE_FILE_PATH__ -exportPath \"$__BUILD_PATH__/$__SCHEME__\" -exportOptionsPlist \"$__EXPORT_OPTIONS_PLIST__\""
    xcodebuild -exportArchive                       \
        -archivePath $__ARCHIVE_FILE_PATH__         \
        -exportPath "$__BUILD_PATH__/$__SCHEME__"   \
        -exportOptionsPlist "$__EXPORT_OPTIONS_PLIST__"

    # 获取应用程序的包名
    __ARCHIVED_APP_NAME__=`ls "$__BUILD_PATH__/$__SCHEME__" | grep .*app$`
    __ARCHIVED_APP_PATH__="$__BUILD_PATH__/$__SCHEME__/$__ARCHIVED_APP_NAME__"
    LOG "打包的app名称: " "$__ARCHIVED_APP_NAME__"
    LOG "app文件位置: " "$__ARCHIVED_APP_PATH__"

    # 如果目录下没有打包文件
    if [ ! -e "$__ARCHIVED_APP_PATH__" ]; then
        LOG "File not exits"
    fi

    #--------------------------------------------------------------------------
    #----------  执行上传公正流程

    # 拷贝dsym文件
    __DSYM_FILE_NAME__=`ls "$__ARCHIVE_FILE_PATH__/dSYMs" | grep .*app\.dSYM`
    __DSYM_FILE_PATH__="$__ARCHIVE_FILE_PATH__/dSYMs/$__DSYM_FILE_NAME__"

    if [ ! -d "$__DSYM_FILE_PATH__" ]; then
        LOG "no dSYM file at $__DSYM_FILE_PATH__"
        exit -1
    fi
    
    LOG "dSYM file at $__DSYM_FILE_PATH__" # .app.dSYM
    # replace ".app.dSYM" to empty string
    tmp_dSYMNAME="${__DSYM_FILE_NAME__/\.app\.dSYM/}_${__APP_VER__}_${__INPUT_CONFIGURATION__}"
    cp -R "$__DSYM_FILE_PATH__" "$__ARCHIVE_DSYM_FOLDER__/$tmp_dSYMNAME.dSYM"


    LOG "解锁钥匙串" "security unlock-keychain -p \"$__MAC_PWD__\" ~/Library/Keychains/login.keychain"
    security unlock-keychain -p "$__MAC_PWD__" ~/Library/Keychains/login.keychain

    LOG "用证书文件签名打包生成的app" "codesign --verify --timestamp --options runtime -f -s \"$__BUILDING_CERT__\" --deep --entitlements \"$__ENTITLEMENTS__\" \"$__ARCHIVED_APP_PATH__\""
    # 在签名的时候可能会遇到这样的错误 The executable does not have the hardened runtime enabled.
    # 需要加上 --options=runtime 即可
    codesign --verify --timestamp -f --options runtime -s "$__BUILDING_CERT__" --deep --entitlements "$__ENTITLEMENTS__" "$__ARCHIVED_APP_PATH__"
    
#        LOG "验证签名信息：" "codesign -dv --verbose=4 \"$__ARCHIVED_APP_PATH__\""
#        codesign -dv --verbose=4 "$__ARCHIVED_APP_PATH__"

#        LOG "查看是否签名成功：" "spctl --verbose=4 --assess --type execute \"$__ARCHIVED_APP_PATH__\""
#        spctl --verbose=4 --assess --type execute "$__ARCHIVED_APP_PATH__"

    __ZIPED_FILE__="$__BUILD_PATH__/$__SCHEME__/singed_$__ARCHIVED_APP_NAME__.zip"
    LOG "将app生成zip格式的文件并移除压缩前的app文件" "ditto -c -k --keepParent \"$__ARCHIVED_APP_PATH__\" \"$__ZIPED_FILE__\" && rm -rf \"$__ARCHIVED_APP_PATH__\""
    ditto -c -k --keepParent "$__ARCHIVED_APP_PATH__" "$__ZIPED_FILE__" && rm -rf "$__ARCHIVED_APP_PATH__"

    # 查询公正信息的文件
    __NOTARIZE_INFO_PLIST__="$__BUILD_PATH__/$__SCHEME__/notarize_info.plist"
    
    LOG "上传zip文件进行公证：" "xcrun notarytool submit \"$__ZIPED_FILE__\" --apple-id $__APPLE_ID__ --team-id $__TEAM_ID__ --password $__2FA_PASSWORD__  --wait --output-format plist > \"$__NOTARIZE_INFO_PLIST__\""
    # 这里也可以使用keychain信息的方式
    # xcrun notarytool store-credentials "NotarizationItemName"  --apple-id  "$Your_AC_USERNAME"  --team-id  "$YourTeamId"  --password "$Your_ACPassword"
    # xcrun notarytool submit "$__ZIPED_FILE__" --keychain-profile $CREDENTIALS --wait --output-format plist > "$__NOTARIZE_INFO_PLIST__"
    xcrun notarytool submit "$__ZIPED_FILE__"   \
        --apple-id $__APPLE_ID__                \
        --team-id $__TEAM_ID__                  \
        --password $__2FA_PASSWORD__            \
        --wait                                  \
        --output-format plist > "$__NOTARIZE_INFO_PLIST__"
    
    if [ ! -f "$__NOTARIZE_INFO_PLIST__" ]; then
        LOG "没有有效的公正信息文件"
        exit -1
    fi
    
    __NOTARIZE_STATUS__=$(/usr/libexec/PlistBuddy -c "print :status" "$__NOTARIZE_INFO_PLIST__")
    LOG "公正结果：" "$__NOTARIZE_STATUS__"
        
    if [ "$__NOTARIZE_STATUS__" != "Accepted" ]; then
        LOG "公正失败"
        exit -1
    fi
    
    LOG "公正成功..."

    LOG "解压公证过的zip后移除" "unzip -q -d \"$__BUILD_PATH__/$__SCHEME__\" \"$__ZIPED_FILE__\" && rm \"$__ZIPED_FILE__\""
    unzip -q -d "$__BUILD_PATH__/$__SCHEME__" "$__ZIPED_FILE__" && rm "$__ZIPED_FILE__"

    LOG "对app添加票据" "xcrun stapler staple -v \"$__BUILD_PATH__/$__SCHEME__/$__ARCHIVED_APP_NAME__\""
    xcrun stapler staple "$__BUILD_PATH__/$__SCHEME__/$__ARCHIVED_APP_NAME__"

    __APP_INFO_PLIST__="./$__BUILD_PATH__/$__SCHEME__/$__ARCHIVED_APP_NAME__/Contents/Info.plist"
    
    # 打包成dmg
    LOG "开始制作DMG文件"
    
    __APP_SHORT_NAME__=$(/usr/libexec/PlistBuddy -c "print :CFBundleDisplayName" "$__APP_INFO_PLIST__")
    LOG "APP显示名 $__APP_SHORT_NAME__"

    __APP_SHORT_VER__=$(/usr/libexec/PlistBuddy -c "print :CFBundleShortVersionString" "$__APP_INFO_PLIST__")
    LOG "APP版本 $__APP_SHORT_VER__"

    __APP_BUILD_VER__=$(/usr/libexec/PlistBuddy -c "print :CFBundleVersion" "$__APP_INFO_PLIST__")
    LOG "APP Build $__APP_BUILD_VER__"

    # 拼接打包的 configuration
    if [[ "$__INPUT_CONFIGURATION__" == "RC" ]]; then
        __DISPLAY_CONFIGURATION__="RC"
    else
        __DISPLAY_CONFIGURATION__=""
    fi

    # https://github.com/LinusU/node-appdmg/issues/159
    # title 不可以用中文，否则无法添加背景图片
    # title 也不可过长(26个字符)，否则制作好的dmg将无法打开
    cat > $__BUILD_PATH__/$__SCHEME__/appdmg.json <<- EOF
{
  "title": " ${__DMG_CONFIG_NAME__} ${__DISPLAY_CONFIGURATION__} ${__APP_SHORT_VER__}",
  "background": "background.png",
  "contents": [
    { "x": 472, "y": 260, "type": "link", "path": "/Applications" },
    { "x": 192, "y": 260, "type": "file", "path": "${__ARCHIVED_APP_NAME__}" }
  ]
}
EOF

    LOG "写入dmg打包配置" "$__BUILD_PATH__/$__SCHEME__/appdmg.json"
    cat "$__BUILD_PATH__/$__SCHEME__/appdmg.json"

    LOG "增加dmg背景资源 ${__BUILDING_TARGET__}.png"
    cp "${__SCRIPT_FOLDER__}/background/${__BUILDING_TARGET__}.png" "$__BUILD_PATH__/$__SCHEME__/background.png"

    # 拼接打包的 configuration
    if [[ "$__INPUT_CONFIGURATION__" == "RC" ]]; then
        __DISPLAY_CONFIGURATION__="RC_"
    elif [[ "$__INPUT_CONFIGURATION__" == "Release" ]]; then
        __DISPLAY_CONFIGURATION__=""
    else
        __DISPLAY_CONFIGURATION__=$__INPUT_CONFIGURATION__
    fi

    __DMG_NAME__="${__DMG_CONFIG_FILE_NAME__}_${__DISPLAY_CONFIGURATION__}${__APP_SHORT_VER__}_${__APP_BUILD_VER__}"

    LOG "制作DMG文件" "appdmg $__BUILD_PATH__/$__SCHEME__/appdmg.json $__ARCHIVE_DMG_FOLDER__/$__DMG_NAME__.dmg"
    appdmg $__BUILD_PATH__/$__SCHEME__/appdmg.json $__ARCHIVE_DMG_FOLDER__/$__DMG_NAME__.dmg
}

# find all valid targets
__temp_targets=`/usr/libexec/PlistBuddy -c "Print :target" "$__PACK_OPTIONS_FILE__" | perl -lne 'print $1 if /^    (\S*) =/'`
for element in ${__temp_targets[@]}
do
    # find all valid configs of $element
    __temp_configs=`/usr/libexec/PlistBuddy -c "Print :target:$element:config" "$__PACK_OPTIONS_FILE__" | perl -lne 'print $1 if /^    (\S*) =/'`
    
    if [[ "${__temp_configs[@]}" =~ "$__INPUT_CONFIGURATION__" ]]; then
        build_package $element
    else
        echo ""
        LOG "No $__INPUT_CONFIGURATION__ configs of $element"
        echo ""
    fi
done


#########################################################################################
#########################################################################################
#########################################################################################


LOG "处理打包结果。。。。"

# 如果有打包目录，才算是打包成功
if [ -d "./$WORKING_PATH" ]; then
    # 当前打包结果移动到的目录
    DESTINATION_DMG="Shared/Packages/${__INPUT_CONFIGURATION__}/${__APP_VER__}"
    if [ ! -d "/Users/`whoami`/$DESTINATION_DMG" ]; then
        mkdir -p ~/$DESTINATION_DMG
    fi

    # 移动打包结果到缓存目录
    LOG "复制打包dmg文件到缓存目录"
    cp -rf ./archived_dmgs/* ~/${DESTINATION_DMG}

    #########################################################################################
    #########################################################################################
    #########################################################################################


    # dSYM目录
    if [[ "${__INPUT_CONFIGURATION__}" == "RC" ]]; then
        DESTINATION_DSYM="Shared/Performance/dSYMs/RC/${__APP_VER__}"
    else
        DESTINATION_DSYM="Shared/Performance/dSYMs/${__APP_VER__}"
    fi
    
    if [ ! -d "/Users/`whoami`/$DESTINATION_DSYM" ]; then
        mkdir -p ~/$DESTINATION_DSYM
    fi

    LOG "复制dSYM文件到缓存目录"
    cp -rf ./archived_dSYMs/* ~/${DESTINATION_DSYM}

    echo "mark build as successed"
else
    echo "No such files in ./build"
fi


LOG "打包结束"
