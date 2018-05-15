#!/bin/bash


# ----------------------------------------------------------------------
# name:         IPABuildShell.sh
# version:      2.1.0
# createTime:   2018-05-04
# description:  iOS 自动打包
# author:       冯立海
# email:        335418265@qq.com
# github:       https://github.com/aa335418265/IPABuildShell
# ----------------------------------------------------------------------

CMD_PlistBuddy="/usr/libexec/PlistBuddy"
CMD_Xcodebuild=$(which xcodebuild)
CMD_Security=$(which security)
CMD_Lipo=$(which lipo)
CMD_Codesign=$(which codesign)


##历史备份目录
Package_Dir=~/Desktop/PackageLog

##临时文件目录
Tmp_Options_Plist_File_Path='/tmp/optionsplist.plist'
Tmp_Log_File_Path=/tmp/`date +"%Y%m%d%H%M%S"`.txt
Tmp_Xcconfig_File_Path="/tmp/build.xcconfig"
##脚本工作目录
Shell_Work_Path=$(pwd)
##脚本文件目录
Shell_File_Path=$(cd `dirname $0`; pwd)



#############################################基本功能#############################################

## 日志格式化输出
function logit() {
    echo -e "\033[32m [IPABuildShell] \033[0m $@"
    echo "	>> $@" >> "$Tmp_Log_File_Path"
}

## 日志格式化输出
function errorExit(){

    echo -e "\033[31m【IPA构建失败】$@ \033[0m"
    exit 1
}

## 日志格式化输出
function warning(){

    echo -e "\033[33m【警告】$@ \033[0m"
}

##字符串版本号比较：大于等于
function versionCompareGE() { test "$(echo "$@" | tr " " "\n" | sort -rn | head -n 1)" == "$1"; }

## 获取xcpretty安装路径
function getXcprettyPath() {
	xcprettyPath=$(which xcpretty)
	echo $xcprettyPath
}

## 初始化XCconfig配置文件
function initXCconfig() {
	local xcconfigFile=$Tmp_Xcconfig_File_Path
	if [[ -f "$xcconfigFile" ]]; then
		## 清空
		> "$xcconfigFile"
	else 
		## 生成文件
		touch "$xcconfigFile"
	fi
}

## 解锁keychain
function unlockKeychain(){
	$CMD_Security unlock-keychain -p "Lihai520" "$HOME/Library/Keychains/login.keychain" 2>/dev/null
}

## 添加一项配置
function setXCconfigWithKeyValue() {

	local key=$1
	local value=$2

	local xcconfigFile=$Tmp_Xcconfig_File_Path
	if [[ ! -f "$xcconfigFile" ]]; then
		exit 1
	fi

	if grep -q "[ ]*$key[ ]*=.*" "$xcconfigFile";then 
		## 进行替换
		sed -i "_bak" "s/[ ]*$key[ ]*=.*/$key = $value/g" "$xcconfigFile"
	else 
		## 进行追加(重定位)
		echo "$key = $value" >>"$xcconfigFile"
	fi
}

##获取Xcode 版本
function getXcodeVersion() {
	local xcodeVersion=`$CMD_Xcodebuild -version | head -1 | cut -d " " -f 2`
	echo $xcodeVersion
}


##xcode 8.3之后使用-exportFormat导出IPA会报错 xcodebuild: error: invalid option '-exportFormat',改成使用-exportOptionsPlist
function generateOptionsPlist(){
	local provisionFile=$1
	if [[ ! -f "$provisionFile" ]]; then
		exit 1
	fi

	local provisionFileTeamID=$(getProvisionfileTeamID "$provisionFile")
	local provisionFileType=$(getProfileType "$provisionFile")
	local provisionFileName=$(getProvisionfileName "$provisionFile")
	local provisionFileBundleID=$(getProfileBundleId "$provisionFile")
	local compileBitcode='<false/>'
	if [[ "$ENABLE_BITCODE" == 'YES' ]]; then
		compileBitcode='<true/>'
	fi


	local plistfileContent="
	<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n
	<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n
	<plist version=\"1.0\">\n
	<dict>\n
	<key>teamID</key>\n
	<string>$provisionFileTeamID</string>\n
	<key>method</key>\n
	<string>$provisionFileType</string>\n
	<key>provisioningProfiles</key>\n
    <dict>\n
        <key>$provisionFileBundleID</key>\n
        <string>$provisionFileName</string>\n
    </dict>\n
	<key>compileBitcode</key>\n
	$compileBitcode\n
	</dict>\n
	</plist>\n
	"
	## 重定向
	echo -e  "$plistfileContent" > "$Tmp_Options_Plist_File_Path"
	# echo "$plistfileContent" > "$Tmp_Options_Plist_File_Path"
	echo '$Tmp_Options_Plist_File_Path'
}

##检查xcodeproj 是否存在
function checkXcodeprojExist() {

	local xcodeprojPath=$(find "$Shell_Work_Path" -maxdepth 1  -type d -name "*.xcodeproj")
	if [[ ! -d "$xcodeprojPath" ]]; then
		exit 1
	fi
	echo  $xcodeprojPath
}

##检查xcworkspace 是否存在
function getXcworkspace() {

	local xcworkspace=$(find "$Shell_Work_Path" -maxdepth 1  -type d -name "*.xcworkspace")
	if [[ -d "$xcworkspace" ]]; then
		echo $xcworkspace
	fi
}

##检查podfile是否存在
function  checkPodfileExist() {

	local podfile=$(find "$Shell_Work_Path" -maxdepth 1  -type f -name "Podfile")
	if [[ ! -f "$podfile" ]]; then
		exit 1
	fi
	echo $podfile
}


## 获取git仓库版本数量
function getGitRepositoryVersionNumbers (){
		## 是否存在.git目录
	local gitRepository=$(find "$Shell_Work_Path" -maxdepth 1  -type d -name ".git")
	if [[ ! -d "$gitRepository" ]]; then
		exit 1
	fi

	local gitRepositoryVersionNumbers=$(git -C "$Shell_Work_Path" rev-list HEAD 2>/dev/null | wc -l | grep -o "[^ ]\+\( \+[^ ]\+\)*")
	if [[ $? -ne 0 ]]; then
		## 可能是git只有在本地，而没有提交到服务器,或者没有网络
		exit 1
	fi
	echo $gitRepositoryVersionNumbers
}

#设置Info.plist文件的构建版本号
function setBuildVersion () {
	local infoPlistFile=$1
	local buildVersion=$2
	if [[ ! -f "$infoPlistFile" ]]; then
		exit 1
	fi
	$CMD_PlistBuddy -c "Set :CFBundleVersion $buildVersion" "$infoPlistFile"
}


##获取签名方式,##设置手动签名,即不勾选：Xcode -> General -> Signing -> Automatically manage signning
## 在xcode 9之前（不包含9），只有在General这里配置是否手动签名，在xcode9之后，多加了一项在setting中
function getCodeSigningStyle
{

	local pbxproj=$1/project.pbxproj
	local targetId=$2
	local rootObject=$($CMD_PlistBuddy -c "Print :rootObject" "$pbxproj")
	if [[ ! -f "$pbxproj" ]]; then
		exit 1
	fi
	##没有勾选过Automatically manage signning时，则不存在ProvisioningStyle
	signingStyle=$($CMD_PlistBuddy -c "Print :objects:$rootObject:attributes:TargetAttributes:$targetId:ProvisioningStyle " "$pbxproj" 2>/dev/null)
	echo $signingStyle

}

##设置签名方式（手动/自动）
function setManulCodeSigning
{
	local pbxproj=$1/project.pbxproj
	local targetId=$2
	local rootObject=$($CMD_PlistBuddy -c "Print :rootObject" "$pbxproj")
	##如果需要设置成自动签名,将Manual改成Automatic
	$CMD_PlistBuddy -c "Set :objects:$rootObject:attributes:TargetAttributes:$targetId:ProvisioningStyle Manual" "$pbxproj"
}

function addManulCodeSigning
{
	local pbxproj=$1/project.pbxproj
	local targetId=$2
	local rootObject=$($CMD_PlistBuddy -c "Print :rootObject" "$pbxproj")
	##如果需要设置成自动签名,将Manual改成Automatic
	$CMD_PlistBuddy -c "Add :objects:$rootObject:attributes:TargetAttributes:$targetId:ProvisioningStyle string Manual" "$pbxproj"
}


#获取,会在当前脚本执行目录以及5级内的子目录下自动寻找

function findAIPEnvFile () {

	local fileName=$1
	## 如果直接是全路径文件,直接返回
	if [[ -f "$fileName" ]]; then
		echo $fileName
		return 
	else
		local apiEnvFile=`find "$Shell_Work_Path" -maxdepth 5 -path "./.Trash" -prune -o -type f -name "$fileName" -print| head -n 1`
		if [[ ! -f "$apiEnvFile" ]]; then
			exit 1
		fi
		echo $apiEnvFile
		return 
	fi
}

## 获取接口环境的值
function getIPEnvValue () {
	local apiEnvFile=$1
	local apiEnvVarName=$2

	if [[ ! -f "$apiEnvFile" ]]; then
		exit 1
	fi
	local apiEnvVarValue=$(grep "$apiEnvVarName" "$apiEnvFile" | grep -v '^//' | cut -d ";" -f 1 | cut -d "=" -f 2 | sed 's/^[ \t]*//g' | sed 's/[ \t]*$//g')
	echo $apiEnvVarValue
}

function setAIPEnvFile () {
	local apiEnvFile=$1
	local apiEnvVarName=$2
	local apiEnvVarValue=$3

	if [[ ! -f "$apiEnvFile" ]]; then
		exit 1
	fi
	sed -i ".bak" "/[ ]*$apiEnvVarName[ ]*=/s/=.*/= $apiEnvVarValue;\/\/脚本自动设置/" "$apiEnvFile" && rm -rf ${apiEnvFile}.bak
}

##获取授权文件过期天数
function getProvisionfileExpirationDays()
{
    local provisionFile=$1

    if [[ ! -f "$provisionFile" ]]; then
    	exit 1
    fi
    ##切换到英文环境，不然无法转换成时间戳
    export LANG="en_US.UTF-8"
    ##获取授权文件的过期时间
    local profileExpirationDate=$($CMD_PlistBuddy -c 'Print :ExpirationDate' /dev/stdin <<< $($CMD_Security cms -D -i "$provisionFile" 2>/dev/null))
    local profileExpirationTimestamp=$(date -j -f "%a %b %d  %T %Z %Y" "$profileExpirationDate" "+%s")
    local nowTimestamp=`date +%s`
    local r=$[profileExpirationTimestamp-nowTimestamp]
    local expirationDays=$[r/60/60/24]
    echo $expirationDays
}

## 获取授权文件UUID
function getProvisionfileUUID()
{
	local provisionFile=$1
	if [[ ! -f "$provisionFile" ]]; then
		exit 1
	fi
	provisonfileUUID=$($CMD_PlistBuddy -c 'Print :UUID' /dev/stdin <<< $($CMD_Security cms -D -i "$provisionFile" 2>/dev/null))
	echo $provisonfileUUID
}

## 获取授权文件TeamID
function getProvisionfileTeamID()
{
	local provisionFile=$1
	if [[ ! -f "$provisionFile" ]]; then
		exit 1
	fi
	provisonfileTeamID=$($CMD_PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' /dev/stdin <<< $($CMD_Security cms -D -i "$provisionFile" 2>/dev/null))
	echo $provisonfileTeamID
}

## 获取授权文件名称
function getProvisionfileName()
{
	local provisionFile=$1
	if [[ ! -f "$provisionFile" ]]; then
		exit 1
	fi
	provisonfileName=$($CMD_PlistBuddy -c 'Print :Name' /dev/stdin <<< $($CMD_Security cms -D -i "$provisionFile" 2>/dev/null))
	echo $provisonfileName
}


##这里只取第一个target id
function getBuildTargetId()
{
	local pbxproj=$1/project.pbxproj
	if [[ ! -f "$pbxproj" ]]; then
		exit 1
	fi
	local rootObject=$($CMD_PlistBuddy -c "Print :rootObject" "$pbxproj")
	local targetList=$($CMD_PlistBuddy -c "Print :objects:${rootObject}:targets" "$pbxproj" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//')
	#括号用于初始化数组,例如arr=(1,2,3)
	local targets=$(echo $targetList);
	##这里，只取第一个target,因为默认情况下xcode project 会有自动生成Tests 以及 UITests 两个target
	local targetId=${targets[0]}
	echo $targetId
}

##这里只取第一个target
function getTargetName()
{
	local pbxproj=$1/project.pbxproj
	local targetId=$2
	if [[ ! -f "$pbxproj" ]]; then
		exit 1
	fi
	local targetName=$($CMD_PlistBuddy -c "Print :objects:$targetId:name" "$pbxproj")
	echo $targetName
}


## 获取配置ID,主要是后续用了获取bundle id
function getConfigurationIds() {

	##配置模式：Debug 或 Release
	local targetId=$2
	local pbxproj=$1/project.pbxproj
	if [[ ! -f "$pbxproj" ]]; then
		exit 1
	fi
  	local buildConfigurationListId=$($CMD_PlistBuddy -c "Print :objects:$targetId:buildConfigurationList" "$pbxproj")
  	local buildConfigurationList=$($CMD_PlistBuddy -c "Print :objects:$buildConfigurationListId:buildConfigurations" "$pbxproj" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//')
  	##数组中存放的分别是release和debug对应的id
  	local configurationTypeIds=$(echo $buildConfigurationList)
  	echo $configurationTypeIds

}

function getConfigurationIdWithType(){

	local configrationType=$3
	local targetId=$2
	local pbxproj=$1/project.pbxproj
	if [[ ! -f "$pbxproj" ]]; then
		exit 1
	fi

	local configurationTypeIds=$(getConfigurationIds "$1" $targetId)
	for id in ${configurationTypeIds[@]}; do
	local name=$($CMD_PlistBuddy -c "Print :objects:$id:name" "$pbxproj")
	if [[ "$configrationType" == "$name" ]]; then
		echo $id
	fi
	done
}

function getInfoPlistFile()
{
	configurationId=$2
	local pbxproj=$1/project.pbxproj
	if [[ ! -f "$pbxproj" ]]; then
		exit 1
	fi
   local  infoPlistFileName=$($CMD_PlistBuddy -c "Print :objects:$configurationId:buildSettings:INFOPLIST_FILE" "$pbxproj" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//')
	  ### 完整路径
	infoPlistFilePath="$1/../$infoPlistFileName"
	echo $infoPlistFilePath
}


## 获取bundle Id,分为Releae和Debug
function getProjectBundleId()
{	
	local configurationId=$2
	local pbxproj=$1/project.pbxproj
	if [[ ! -f "$pbxproj" ]]; then
		exit 1
	fi
	local bundleId=$($CMD_PlistBuddy -c "Print :objects:$configurationId:buildSettings:PRODUCT_BUNDLE_IDENTIFIER" "$pbxproj" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//')
	echo $bundleId
}


################################################################################################
##匹配签名身份
function matchCodeSignIdentity()
{
	local provisionFile=$1
	local channel=$2
	local channelFilterString=''
	local startSearchString=''
	local endSearchString='1\\0230\\021\\006\\003U\\004'


	if [[ ! -f "$provisionFile" ]]; then
		exit 1;
	fi

	if [[ "$channel" == 'enterprise' ]] || [[ "$channel" == 'app-store' ]]; then
		channelFilterString='iPhone Distribution: '
		startSearchString='003U\\004\\003\\0142'
	else
		channelFilterString='iPhone Developer: '
		startSearchString='003U\\004\\003\\014&'
	fi
	profileTeamId=$($CMD_PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' /dev/stdin <<< $($CMD_Security cms -D -i "$provisionFile" 2>/dev/null))
	codeSignIdentity=$($CMD_Security dump-keychain 2>/dev/null | grep "\"subj\"<blob>=" | cut -d '=' -f 2 | grep "$profileTeamId" | awk -F "[\"\"]" '{print $2}' | grep "$channelFilterString" | sed "s/\(.*\)$startSearchString\(.*\)$endSearchString\(.*\)/\2/g" | head -n 1)
	echo "$codeSignIdentity"
}

##匹配授权文件
function matchMobileProvisionFile()
{	

	##分发渠道
	local channel=$1
	local appBundleId=$2
	##授权文件目录
	local mobileProvisionFileDir=$3
	if [[ ! -d "$mobileProvisionFileDir" ]]; then
		exit 1
	fi
	##遍历
	for file in "${mobileProvisionFileDir}"/*.mobileprovision; do
		local bundleIdFromProvisionFile=$(getProfileBundleId "$file")
		if [[ "$bundleIdFromProvisionFile" ]] && [[ "$appBundleId" == "$bundleIdFromProvisionFile" ]]; then
			local profileType=$(getProfileType "$file")
			if [[ "$profileType" == "$channel" ]]; then
				echo "$file"
				return 
			fi
		fi
	done
	exit 1
}



function getProfileBundleId()
{
	local profile=$1
	local applicationIdentifier=$($CMD_PlistBuddy -c 'Print :Entitlements:application-identifier' /dev/stdin <<< "$($CMD_Security cms -D -i "$profile" 2>/dev/null )")
	if [[ $? -ne 0 ]]; then
		exit 1;
	fi
	##截取bundle id,这种截取方法，有一点不太好的就是：当applicationIdentifier的值包含：*时候，会截取失败,如：applicationIdentifier=6789.*
	local bundleId=${applicationIdentifier#*.}
	echo $bundleId
}

##获取授权文件类型
function getProfileType()
{
	local profile=$1
	local profileType=''
	if [[ ! -f "$profile" ]]; then
		exit 1
	fi
	##判断是否存在key:ProvisionedDevices
	local haveKey=$($CMD_Security cms -D -i "$profile" 2>/dev/null | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//' | grep ProvisionedDevices)
	if [[ "$haveKey" ]]; then
		local getTaskAllow=$($CMD_PlistBuddy -c 'Print :Entitlements:get-task-allow' /dev/stdin <<< $($CMD_Security cms -D -i "$profile" 2>/dev/null ) )
		if [[ $getTaskAllow == true ]]; then
			profileType='development'
		else
			profileType='ad-hoc'
		fi
	else

		local haveKeyProvisionsAllDevices=$($CMD_Security cms -D -i "$profile" 2>/dev/null | grep ProvisionsAllDevices)
		if [[ "$haveKeyProvisionsAllDevices" != '' ]]; then
			provisionsAllDevices=$($CMD_PlistBuddy -c 'Print :ProvisionsAllDevices' /dev/stdin <<< "$($CMD_Security cms -D -i "$profile" 2>/dev/null)" )
			if [[ $provisionsAllDevices == true ]]; then
				profileType='enterprise'
			else
				profileType='app-store'
			fi
		else
			profileType='app-store'
		fi
	fi
	echo $profileType
}

## 获取profile type的中文名字
function getProfileTypeCNName()
{
    local profileType=$1
    local profileTypeName
    if [[ "$profileType" == 'app-store' ]]; then
        profileTypeName='商店分发'
    elif [[ "$profileType" == 'enterprise' ]]; then
        profileTypeName='企业分发'
    else
        profileTypeName='内部测试'
    fi
    echo $profileTypeName

}

function historyBackup() {

		## 备份上一次的打包数据
	if [[ -d "$Package_Dir" ]]; then
		for name in `ls $Package_Dir` ; do
			if [[ "$name" == "History" ]] && [[ -d "$Package_Dir/$name" ]]; then
				continue;
			fi
			cp -rf "$Package_Dir/$name" "$Package_Dir/History"
			rm -rf "$Package_Dir/$name"
		done
	fi
}

### 开始构建归档，因为该函数里面逻辑较多，所以在里面添加了日志打印
function archiveBuild()
{
	local targetName=$1
	local xcconfigFile=$2
	local xcworkspacePath=$(getXcworkspace)

	## 暂时使用全局变量---
	archivePath="${Package_Dir}"/$targetName.xcarchive



	####################进行归档########################
	local cmd="$CMD_Xcodebuild archive"
	if [[ "$xcworkspacePath" ]]; then
		cmd="$cmd"" -workspace \"$xcworkspacePath\""
	fi
	cmd="$cmd"" -scheme $targetName -archivePath \"$archivePath\" -configuration $CONFIGRATION_TYPE -xcconfig $xcconfigFile clean build"

	local xcpretty=$(getXcprettyPath)
	if [[ "$xcpretty" ]]; then
		## 格式化日志输出
		cmd="$cmd"" | xcpretty "
	fi

	# 执行构建，set -o pipefail 为了获取到管道前一个命令xcodebuild的执行结果，否则$?一直都会是0
	eval "set -o pipefail && $cmd " 
	if [[ $? -ne 0 ]]; then
		errorExit "归档失败，请检查编译日志(编译错误、签名错误等)。"
	fi


	# echo "$archivePath"
}


function testIPA() 
{	
	local exportPath='123456'
	cmd='/usr/bin/xcodebuild -exportArchive -archivePath "/Users/itx/Desktop/PackageLog/Test.xcarchive" -exportPath "/Users/itx/Desktop/PackageLog" -exportOptionsPlist "$Tmp_Options_Plist_File_Path" | xcpretty -c'
	eval "set -o pipefail && $cmd"
	if [[ $? -ne 0 ]]; then
		exit 1
	fi
	echo $exportPath

}

function exportIPA() {

	local archivePath=$1
	local provisionFile=$2
	local targetName=${archivePath%.*}
	targetName=${targetName##*/}
	local xcodeVersion=$(getXcodeVersion)
	local exportPath="${Package_Dir}"/${targetName}.ipa

	if [[ ! -f "$provisionFile" ]]; then
		exit 1
	fi

	####################进行导出IPA########################
	local cmd="$CMD_Xcodebuild -exportArchive"
	## >= 8.3
	if versionCompareGE "$xcodeVersion" "8.3"; then
		local optionsPlistFile=$(generateOptionsPlist "$provisionFile")
		 cmd="$cmd"" -archivePath \"$archivePath\" -exportPath \"$Package_Dir\" -exportOptionsPlist \"$optionsPlistFile\""
	else
		cmd="$cmd"" -exportFormat IPA -archivePath \"$archivePath\" -exportPath \"$exportPath\""
	fi
	##判断是否安装xcpretty
	xcpretty=$(getXcprettyPath)
	if [[ "$xcpretty" ]]; then
		## 格式化日志输出
		cmd="$cmd | xcpretty -c"
	fi
	## 这里需要添加>/dev/null 2>&1; ，否则echo exportPath 作为函数返回参数，会带有其他信息
	eval "set -o pipefail && $cmd" >/dev/null 2>&1;
	if [[ $? -ne 0 ]]; then
		exit 1
	fi
	echo $exportPath
}



##在打企业包的时候：会报 archived-expanded-entitlements.xcent  文件缺失!这是xcode的bug
##链接：http://stackoverflow.com/questions/28589653/mac-os-x-build-server-missing-archived-expanded-entitlements-xcent-file-in-ipa
function repairXcentFile
{

### xcode 9.0 已经修复该问题了，所以针对xcode 9.0 以下进行修复。

	
	local exportPath=$1
	local archivePath=$2

	local xcodeVersion=$(getXcodeVersion)

	if ! versionCompareGE "$xcodeVersion" "9.0"; then

		local appName=`basename "$exportPath" .ipa`
		xcentFile="${archivePath}"/Products/Applications/"${appName}".app/archived-expanded-entitlements.xcent
		if [[ -f "$xcentFile" ]]; then
			# logit  "修复xcent文件：\"$xcentFile\" "
			logit  "archived-expanded-entitlements.xcent 文件：已修复"
			unzip -o "$exportPath" -d /"$Package_Dir" >/dev/null 2>&1
			local app="${Package_Dir}"/Payload/"${appName}".app
			cp -af "$xcentFile" "$app" >/dev/null 2>&1
			##压缩,并覆盖原有的ipa
			cd "${Package_Dir}"  ##必须cd到此目录 ，否则zip会包含绝对路径
			zip -qry  "$exportPath" Payload >/dev/null 2>&1 && rm -rf Payload
			cd - >/dev/null 2>&1
		else
			logit  "xcent 无需修复"
		fi
	fi

}


#构建完成，检查App
function checkIPA()
{
	local exportPath=$1
	if [[ ! -f "$exportPath" ]]; then
		exit 1
	fi
	local ipaName=`basename "$exportPath" .ipa`
	##解压强制覆盖，并不输出日志
	if [[ -d "${Package_Dir}/Payload" ]]; then
		rm -rf "${Package_Dir}/Payload"
	fi
	unzip -o "$exportPath" -d ${Package_Dir} >/dev/null 2>&1
	
	local app=${Package_Dir}/Payload/"${ipaName}".app
	codesign --no-strict -v "$app"
	if [[ $? -ne 0 ]]; then
		errorExit "签名检查：签名校验不通过！"
	fi
	logit "【签名校验】签名校验通过！"
	if [[ -d "$app" ]]; then
		local ipaInfoPlistFile=${app}/Info.plist
		local mobileProvisionFile=${app}/embedded.mobileprovision
		local appShowingName=`$CMD_PlistBuddy -c "Print :CFBundleName" $ipaInfoPlistFile`
		local appBundleId=`$CMD_PlistBuddy -c "print :CFBundleIdentifier" "$ipaInfoPlistFile"`
		local appVersion=`$CMD_PlistBuddy -c "Print :CFBundleShortVersionString" $ipaInfoPlistFile`
		local appBuildVersion=`$CMD_PlistBuddy -c "Print :CFBundleVersion" $ipaInfoPlistFile`
		local appMobileProvisionName=`$CMD_PlistBuddy -c 'Print :Name' /dev/stdin <<< $($CMD_Security cms -D -i "$mobileProvisionFile" 2>/dev/null)`
		local appMobileProvisionCreationDate=`$CMD_PlistBuddy -c 'Print :CreationDate' /dev/stdin <<< $($CMD_Security cms -D -i "$mobileProvisionFile" 2>/dev/null)`
        #授权文件有效时间
		local appMobileProvisionExpirationDate=`$CMD_PlistBuddy -c 'Print :ExpirationDate' /dev/stdin <<< $($CMD_Security cms -D -i "$mobileProvisionFile" 2>/dev/null)`
		local provisionFileExpirationDays=$(getProvisionfileExpirationDays "$mobileProvisionFile")



		local provisionType=$(getProfileType "$mobileProvisionFile")
		local channelName=$(getProfileTypeCNName $provisionType)

		local appCodeSignIdenfifier=$($CMD_Codesign -dvvv "$app" 2>/tmp/log.txt &&  grep Authority /tmp/log.txt | head -n 1 | cut -d "=" -f2)
		#支持最小的iOS版本
		local supportMinimumOSVersion=$($CMD_PlistBuddy -c "print :MinimumOSVersion" "$ipaInfoPlistFile")
		#支持的arch
		local supportArchitectures=$($CMD_Lipo -info "$app"/"$ipaName" | cut -d ":" -f 3)

		logit "【IPA 信息】名字:$appShowingName"
		# getEnvirionment
		# logit "配置环境kBMIsTestEnvironment:$currentEnvironmentValue"
		logit "【IPA 信息】bundleID:$appBundleId"
		logit "【IPA 信息】版本:$appVersion"
		logit "【IPA 信息】build:$appBuildVersion"
		logit "【IPA 信息】支持最低iOS版本:$supportMinimumOSVersion"

		logit "【IPA 信息】支持的archs:$supportArchitectures"
		logit "【IPA 信息】签名:$appCodeSignIdenfifier"
		logit "【IPA 信息】授权文件:${appMobileProvisionName}.mobileprovision"
		logit "【IPA 信息】授权文件创建时间:$appMobileProvisionCreationDate"
		logit "【IPA 信息】授权文件过期时间:$appMobileProvisionExpirationDate"
        logit "【IPA 信息】授权文件有效天数：${provisionFileExpirationDays} 天"
        logit "【IPA 信息】授权文件分发渠道：${channelName}($provisionType)"



	else
		errorExit "解压失败！无法找到$app"
	fi
}




## 默认配置
CONFIGRATION_TYPE='Release'
ARCHS='arm64'
CHANNEL='development'
ENABLE_BITCODE='NO'
DEBUG_INFORMATION_FORMAT='dwarf'

AUTO_BUILD_VERSION=false

## 为了方便脚本配置接口环境（测试/正式）,需要3个参数分别是：接口环境配置文件名、接口环境变量名、接口环境变量值
ENV_FILE_NAME=''
ENV_VARNAME=''
ENV_VARVALUE=''
PROVISION_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"

while [ "$1" != "" ]; do
    case $1 in
        -b | --bundle-id )
            shift
            NEW_BUNDLE_IDENTIFIER=("$1")
            ;;
        -c | --channel )
            shift
            CHANNEL="$1"
            ;;
        -d | --provision-dir )
            shift
            PROVISION_DIR="$1"
            ;;
        -t | --configration-type )
            shift
            CONFIGRATION_TYPE="$1"
            ;;
        -a| --archs )
            shift
            ARCHS="$1"
            ;;
      	--enable-bitcode )
            ENABLE_BITCODE='YES'
            ;;
      	--auto-buildversion )
            AUTO_BUILD_VERSION=true
            ;;

      	--env-filename )
			shift
            ENV_FILE_NAME="$1"
            ;;
    	--env-varname)
			shift
	        ENV_VARNAME="$1"
	        ;;
    	--env-varvalue)
			shift
	        ENV_VARVALUE="$1"
	        ;;
        -v | --verbose )
            VERBOSE="--verbose"
            ;;
        -h | --help )
            usage
            ;;
        * )
            [[ -n "$NEW_FILE" ]] && error "Multiple output file names specified!"
            [[ -z "$NEW_FILE" ]] && NEW_FILE="$1"
            ;;
    esac

    # Next arg
    shift
done


historyBackup


if [[ $? -eq 0 ]]; then
	logit "【数据备份】上一次打包文件已备份到：$Package_Dir/History"	
fi


### Xcode版本
xcVersion=$(getXcodeVersion)
if [[ ! "$xcVersion" ]]; then
	errorExit "获取当前XcodeVersion失败"
fi
logit "【构建信息】Xcode版本：$xcVersion"


xcodeprojPath=$(checkXcodeprojExist)
if [[ ! "$xcodeprojPath" ]]; then
	errorExit "当前目录不存在Xcodeproj文件，请在工程目录下执行脚本$(basename $0)"
fi


## 获取构建target Id
targetId=$(getBuildTargetId "$xcodeprojPath")
if [[ ! "$targetId" ]]; then
	errorExit "获取构建Target Id失败"
fi
logit "【构建信息】Target Id：$targetId"

## 获取target名称
targetName=$(getTargetName "$xcodeprojPath" $targetId)
if [[ ! "$targetName" ]]; then
	errorExit "获取构建Target名字失败"
fi
logit "【构建信息】Target 名字：$targetName"


##获取构配置类型的ID （Release和Debug分别对应不同的ID）
configurationTypeIds=$(getConfigurationIds "$xcodeprojPath" "$targetId")
if [[ ! "$configurationTypeIds" ]]; then
	errorExit "获取配置模式(Release和Debug)Id列表失败"
fi
logit "【构建信息】配置模式(Release和Debug)Id列表：$configurationTypeIds"



## 获取当前构建的配置模式ID
configurationId=$(getConfigurationIdWithType "$xcodeprojPath" "$targetId" "$CONFIGRATION_TYPE")
if [[ ! "$configurationId" ]]; then
	errorExit "获取${CONFIGRATION_TYPE}配置模式Id失败"
fi
logit "【构建信息】配置模式：$CONFIGRATION_TYPE"
logit "【构建信息】配置模式Id：$configurationId"



## 获取Bundle Id
if [[ $NEW_BUNDLE_IDENTIFIER ]]; then
	## 重新指定Bundle Id
	projectBundleId=$NEW_BUNDLE_IDENTIFIER
else
	## 获取工程中的Bundle Id
	projectBundleId=$(getProjectBundleId "$xcodeprojPath" "$configurationId")
	if [[ ! "$projectBundleId" ]] ; then
		errorExit "获取项目的Bundle Id失败"
	fi
fi
logit "【构建信息】Bundle Id：$projectBundleId"

infoPlistFile=$(getInfoPlistFile "$xcodeprojPath" "$configurationId")
if [[ ! "$infoPlistFile" ]]; then
	errorExit "获取infoPlist文件失败"
fi
logit "【构建信息】InfoPlist 文件：$infoPlistFile"

## 设置git仓库版本数量
gitRepositoryVersionNumbers=$(getGitRepositoryVersionNumbers)
if [[ $AUTO_BUILD_VERSION == true ]] && [[ "$gitRepositoryVersionNumbers" ]]; then
	setBuildVersion "$infoPlistFile" "$gitRepositoryVersionNumbers"
	if [[ $? -ne 0 ]]; then
		warning "设置构建版本号失败，跳过此设置"
	else
		logit "【构建信息】设置构建版本号：$gitRepositoryVersionNumbers"
	fi
	

fi

## 设置环境变量
apiEnvFile=$(findAIPEnvFile "$ENV_FILE_NAME")
if [[ "$apiEnvFile" ]]; then
	logit "【构建信息】API环境配置文件：$apiEnvFile"
	if [[ "$ENV_VARNAME" ]] && [[ "$ENV_VARVALUE" ]]; then
		setAIPEnvFile "$apiEnvFile" "$ENV_VARNAME" "$ENV_VARVALUE"
		if [[ $? -ne 0 ]]; then
			warning "设置API环境变量失败，跳过此设置"
		else
			logit "【构建信息】设置API环境变量：$ENV_VARNAME = $ENV_VARVALUE"
		fi
	fi
fi


## 设置手动签名
codeSigningStyle=$(getCodeSigningStyle "$xcodeprojPath" "$targetId")
if [[ ! "$codeSigningStyle" ]]; then
	
	## 添加手动签名配置
	addManulCodeSigning "$xcodeprojPath" "$targetId"
	if [[ $? -ne 0 ]]; then
		errorExit "设置General手动签名失败"
	else
		logit "【签名信息】设置手动签名"
	fi
else
	if [[ "$codeSigningStyle" != "Manual" ]]; then
		setManulCodeSigning "$xcodeprojPath" "$targetId"
		if [[ $? -eq 0 ]]; then
			logit "【签名信息】设置手动签名"
		fi
	fi
fi


## 匹配授权文件
provisionFile=$(matchMobileProvisionFile "$CHANNEL" "$projectBundleId" "$PROVISION_DIR")
if [[ ! "$provisionFile" ]]; then
	errorExit "不存在Bundle Id 为 ${projectBundleId} 且分发渠道为${CHANNEL}的授权文件，请检查${PROVISION_DIR}目录是否存在对应授权文件"

fi
## 授权文件type对应的名字
channelName=$(getProfileTypeCNName $CHANNEL)
## 获取授权文件的有效天数
provisionFileExpirationDays=$(getProvisionfileExpirationDays "$provisionFile")
provisionFileName=$(getProvisionfileName "$provisionFile")
provisionFileTeamID=$(getProvisionfileTeamID "$provisionFile")
provisionFileUUID=$(getProvisionfileUUID "$provisionFile")


logit "【授权文件】匹配文件Bundle Id：${projectBundleId}"
logit "【授权文件】匹配文件路径：${provisionFile}"
logit "【授权文件】匹配文件名称：${provisionFileName}"
logit "【授权文件】匹配文件TeamID：${provisionFileTeamID}"
logit "【授权文件】匹配文件UUID：${provisionFileUUID}"
logit "【授权文件】匹配文件分发渠道：${CHANNEL}(${channelName})"
logit "【授权文件】匹配文件有效天数：${provisionFileExpirationDays}"


## 匹配签名ID
codeSignIdentity=$(matchCodeSignIdentity "$provisionFile" $CHANNEL)
if [[ ! "$codeSignIdentity" ]]; then
	errorExit "不存在授权文件${provisionFile} 且分发渠道为${CHANNEL}的签名"
fi

logit "【签名身份】匹配签名ID：$codeSignIdentity"




### 进行构建配置信息覆盖，关闭BitCode、签名手动、配置签名等
initXCconfig 


setXCconfigWithKeyValue "ENABLE_BITCODE" "$ENABLE_BITCODE"
setXCconfigWithKeyValue "DEBUG_INFORMATION_FORMAT" "$DEBUG_INFORMATION_FORMAT"
setXCconfigWithKeyValue "CODE_SIGN_STYLE" "Manual"
setXCconfigWithKeyValue "PROVISIONING_PROFILE_SPECIFIER" "$provisionFileName" 
setXCconfigWithKeyValue "PROVISIONING_PROFILE" "$provisionFileUUID"
setXCconfigWithKeyValue "DEVELOPMENT_TEAM" "$provisionFileTeamID"
setXCconfigWithKeyValue "CODE_SIGN_IDENTITY" "$codeSignIdentity"
setXCconfigWithKeyValue "PRODUCT_BUNDLE_IDENTIFIER" "$projectBundleId"

## 如果是进行商店分发或则企业分发，那么构建标准arch（即armv7和arm64）
if [[ "$CHANNEL" == 'app-store' ]]|| [[ "$CHANNEL" == 'enterprise' ]] ; then
	setXCconfigWithKeyValue "ARCHS" "armv7 arm64"
else
	## 构建默认arch或者用户指定archs
	setXCconfigWithKeyValue "ARCHS" "$ARCHS"
fi



## podfile 检查
podfile=$(checkPodfileExist)
if [[ "$podfile" ]]; then
	pod install
fi




## 开始归档。

## 这里使用a=$(...)这种形式会导致xocdebuild日志只能在函数archiveBuild执行完毕的时候输出；
## archivePath 在函数archiveBuild 是全局变量
archiveBuild "$targetName" "$Tmp_Xcconfig_File_Path" 
logit "【归档信息】项目构建成功，文件路径：$archivePath"



# 开始导出IPA
exportPath=$(exportIPA  "$archivePath" "$provisionFile")

if [[ ! "$exportPath" ]]; then
	errorExit "IPA导出失败，请检查日志。"
fi

logit "【IPA 导出】IPA导出成功，文件路径：$exportPath"


checkIPA "$exportPath"










