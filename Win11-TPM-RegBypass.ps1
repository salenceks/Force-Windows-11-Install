param
(
    [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
    [string]
    $Source,

    [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
    [string]
    $Destination,

    [switch]
    $InjectVMwareTools = $false,

    [switch]
    $InjectPostPatch = $false,

    [switch]
    $GuiSelectMode = $false,

    [switch]
    $HideTimestamps = $false,

    [switch]
    $VerboseMode = $false,

    [switch]
    $UpgradeMode = $false,

    [switch]
    $SkipReg = $false
)

process
{
    Function MakeDirectory ($path) {
        if($VerboseMode) {
            mkdir $path
        } else {
            (mkdir $path) > $null
        }
    }

    Function FormatTimespan {
        $totalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsedTime.Ticks)
        return $totalTime
    }

    Function PrintTimespan ($strPrefix, $inputTimespan) {
        if($HideTimestamps -eq $false) {
            $strOutput = ""
            $strOutput += $strPrefix
            $strOutput += FormatTimespan $inputTimespan
            Write-Host $strOutput -ForegroundColor Green
        }
    }

    # Import DISM module
    $DISMModule_ErrorMessage = "Could not import DISM module. It may not be installed."
    try {
        Import-Module -Name DISM -ErrorAction SilentlyContinue -ErrorVariable dismError
        if ($dismError) {
            # Something bad happened. Likely the module doesn't exist.
            Write-Host $DISMModule_ErrorMessage -ForegroundColor Red
            Exit
        }
    }
    catch {
        # We're not supposed to be here, either.
        Write-Host $DISMModule_ErrorMessage -ForegroundColor Red
        Exit
    }

    $OldLocation = Get-Location

    # Base64-encoded files & definitions
        #!!!DO NOT MODIFY THESE LINES!!!
        # The encoded version (Base64) of the registry keys to be applied to the boot.wim file to bypass TPM and Secure Boot checks
    $REGISTRY_KEY_FILE_B64 = "//5XAGkAbgBkAG8AdwBzACAAUgBlAGcAaQBzAHQAcgB5ACAARQBkAGkAdABvAHIAIABWAGUAcgBzAGkAbwBuACAANQAuADAAMAANAAoADQAKAFsASABLAEUAWQBfAEwATwBDAEEATABfAE0AQQBDAEgASQBOAEUAXABTAFkAUwBUAEUATQBcAFMAZQB0AHUAcABcAEwAYQBiAEMAbwBuAGYAaQBnAF0ADQAKACIAQgB5AHAAYQBzAHMAVABQAE0AQwBoAGUAYwBrACIAPQBkAHcAbwByAGQAOgAwADAAMAAwADAAMAAwADEADQAKACIAQgB5AHAAYQBzAHMAUwBlAGMAdQByAGUAQgBvAG8AdABDAGgAZQBjAGsAIgA9AGQAdwBvAHIAZAA6ADAAMAAwADAAMAAwADAAMQANAAoADQAKAA=="
        #!!!DO NOT MODIFY THESE LINES!!!
    
    $DefaultWindowStyle = "Normal"
    $ActivityName = "Win11-TPM-Bypass"

    # if($VerboseMode) {
    #     $DefaultWindowStyle = "Normal"
    # }

    # Declarations

    $ScriptDir = Split-Path $script:MyInvocation.MyCommand.Path
    #$ScriptExec = $script:MyInvocation.MyCommand.Path

    $7ZipExecutable = Join-Path -Path $ScriptDir -ChildPath "7z\7z.exe"
    $oscdimgExecutable = ".\oscdimg\oscdimg"
    $oscdimgExecutableFull = Join-Path -Path $ScriptDir -ChildPath "oscdimg\oscdimg.exe"

    $ScratchDir = "C:\Scratch"
    $WIMScratchDir = Join-Path -Path $ScratchDir -ChildPath "WIM"
    $Win11ScratchDir = Join-Path -Path $ScratchDir -ChildPath "W-ISO"
    $BootWIMFilePath = Join-Path -Path $Win11ScratchDir -ChildPath "sources\boot.wim"
    $InstallWIMFilePath = Join-Path -Path $Win11ScratchDir -ChildPath "sources\install.wim"
    $InstallWIMMountPath = Join-Path -Path $ScratchDir -ChildPath "INSTALL_WIM"
    $BootWimImageIndex = 2

    $sb_bypass_keyname = "win11-tpm-sb-bypass"
    $sb_bypass_key = Join-Path -Path $Win11ScratchDir -ChildPath ("\sources\" + $sb_bypass_keyname)

    $PostSetupScriptsPath = "Windows\Setup\Scripts"
    $PostPatchCMDFilename = "SkipTPM.cmd"
    $PostPatchPS1Filename = "SkipTPM.ps1"

    $Temp_PostSetupOperations = Join-Path -Path $ScratchDir -ChildPath "PostSetup"
    $Temp_PostSetupOperations_ScriptDirectory = Join-Path -Path $Temp_PostSetupOperations -ChildPath $PostSetupScriptsPath

    $VMwareTempFolderName = "vmwaretools"
    $VMwareToolsScratchDir = Join-Path -Path $Temp_PostSetupOperations -ChildPath "vmwaretools"
    #$MountDir_Setup = Join-Path -Path $VMwareToolsScratchDir -ChildPath $PostSetupScriptsPath
    $VMwareToolsISOPath = Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "VMware\VMware Workstation\windows.iso"

    $PostPatch_WMISubscriptionName = 'Skip TPM Check on Dynamic Update'

    Function GetPercentageFromRange ($value, $minV, $maxV) {
        $percentage = ($value - $minV) / ($maxV - $minV)
        return [int] ($percentage * 100)
    }

    Function Test-CommandExists {
        Param ($command)
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'stop'
        try {if(Get-Command $command){return $true}}
        Catch {return $false}
        Finally {$ErrorActionPreference=$oldPreference}
    }

    Function VerifySwitches {
        # VMware Tools Switch
        if($InjectVMwareTools) {
            if (!(Test-Path $VMwareToolsISOPath)) {
                Write-Host "VMware Tools doesn't seem to exist at the path we expected it to be ($VMwareToolsISOPath)." -ForegroundColor Red
                Pause
                Exit
            }
        }
    }

    Function AdminPrivleges {
        return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    Function CleanupScratch {
        if(Test-Path $ScratchDir) {
            # Write-Host "INFO: Deleting old Scratch directory..." -ForegroundColor Yellow
            DISM_DismountAllImages
            Remove-Item -Path $ScratchDir -Force -Recurse
        }
    }
    
    Function CollectGarbage {
        Write-Host "Cleaning up..."
        [gc]::Collect(1000, [System.GCCollectionMode]::Forced , $true) # Clean up
        [gc]::WaitForPendingFinalizers() # Wait for cleanup process to finish
        #Start-Sleep 1
    }    
    
    Function DISM_DismountAllImages {
        Write-Host "Dismounting all mounted Windows images..."
        #Get-WindowsImage -Mounted -ErrorAction Stop | ForEach-Object {
	    #    Dismount-WindowsImage -Path $_.Path -Discard #-ErrorAction Stop
        #}
        Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images" | Get-ItemProperty | Select-Object -ExpandProperty "Mount Path" | ForEach-Object {Dismount-WindowsImage -Path $_ -Discard}
    }

    Function TerminateS_Premature {
        CollectGarbage
        CleanupScratch | Out-Null
        Write-Host "Process terminated."
        Exit
    }

    # Alert the user if the source image has already been modified by this tool
    Function Alert_ImageModified {
        # $inputF = Read-Host -Prompt "Are you sure you want to continue? [y/n]"
        $inputF = Read-Host -Prompt "Continue anyway? [y/n]"
        if(($inputF -ne "y") -and ($inputF -ne "n"))
        {
            Write-Host "Invalid input: $inputF" -ForegroundColor Red
            Alert_ImageModified
        }
        else
        {
            if($inputF -eq "n")
            {
                TerminateS_Premature
            }
        }
    }

    # Check to see if the destination image exists before continuing.
    Function Alert_DestinationImageAlreadyExists {
        $inputF = Read-Host -Prompt "The destination image already exists. Do you want to overwrite it? [y/n]"
        if(($inputF -ne "y") -and ($inputF -ne "n"))
        {
            Write-Host "Invalid input: $inputF" -ForegroundColor Red
            Alert_DestinationImageAlreadyExists
        }
        else
        {
            if($inputF -eq "n")
            {
                TerminateS_Premature
            }
            if($inputF -eq "y")
            {
                Remove-Item -Path $Destination -Force
            }
        }
    }

    Function AnnounceProgress_RunningExtraTasks {
        Write-Progress -Activity $ActivityName -Status "Executing extra tasks..." -PercentComplete 75
    }

    if(Test-Path $Destination)
    {
        Alert_DestinationImageAlreadyExists
    }

    # Features
    Function InjectRegistryKeys {
        # Mount and edit the setup environment's registry
        Write-Progress -Activity $ActivityName -Status "Editing image registry..." -PercentComplete 60
        $REG_System = Join-Path $WIMScratchDir -ChildPath "\Windows\System32\config\system"
        $VirtualRegistryPath_SYSTEM = "HKLM\WinPE_SYSTEM"
        $VirtualRegistryPath_Setup = $VirtualRegistryPath_SYSTEM + "\Setup"
        # $VirtualRegistryPath_LabConfig = $VirtualRegistryPath_Setup + "\LabConfig"
        reg unload $VirtualRegistryPath_SYSTEM | Out-Null # Just in case...
        Start-Sleep 1
        reg load $VirtualRegistryPath_SYSTEM $REG_System | Out-Null
        Set-Location -Path Registry::$VirtualRegistryPath_Setup
        New-Item -Name "LabConfig"
        #Start-Sleep 1
        New-ItemProperty -Path "LabConfig" -Name "BypassTPMCheck" -Value 1 -PropertyType DWORD -Force
        #Start-Sleep 1
        New-ItemProperty -Path "LabConfig" -Name "BypassSecureBootCheck" -Value 1 -PropertyType DWORD -Force
        #Start-Sleep 1
        New-ItemProperty -Path "LabConfig" -Name "BypassRAMCheck" -Value 1 -PropertyType DWORD -Force
        #Start-Sleep 1
        Set-Location -Path $ScriptDir
        CollectGarbage
        Start-Sleep 1
        reg unload $VirtualRegistryPath_SYSTEM
        # Start-Sleep 1
    }

    Function GeneratePostSetupFileStructure {
        # Create the directory structure that will be replicated on the installation images
        MakeDirectory $Temp_PostSetupOperations
        MakeDirectory $Temp_PostSetupOperations_ScriptDirectory
        
        # Generate SetupComplete.cmd file
        $SetupCompleteCMD = Join-Path -Path $Temp_PostSetupOperations_ScriptDirectory -ChildPath "SetupComplete.cmd"

        if($InjectVMwareTools) { 
            # Add commands to SetupComplete.cmd file to make the VMware Tools installer run on first boot

            $VMwareInstall = 
@"
C:\$VMwareTempFolderName\setup64.exe /S /v "/qn REBOOT=R ADDLOCAL=ALL"
rmdir C:\$VMwareTempFolderName /s /q
"@
            # Copy the contents of the installer to the root of the structure; folder name defined by $VMwareTempFolderName
            
            # Make our temporary directory for VMware Tools
            MakeDirectory $VMwareToolsScratchDir # C:/Scratch/PostSetup/vmware
            # Extract the VMware Tools ISO to that directory
            & $7ZipExecutable x $VMwareToolsISOPath ("-o" + ($VMwareToolsScratchDir)) | Out-Null
        }
        if($InjectPostPatch) { $PatchInject =
@"
:: cmd /c start /wait C:\$PostSetupScriptsPath\$PostPatchCMDFilename
powershell.exe -executionpolicy Bypass -file "C:\$PostSetupScriptsPath\$PostPatchPS1Filename"
"@ }

        # Finally, combine all of the SetupComplete commands into a single string to be written to the file.
        $SetupCompleteCMDContents = 
@"
$PatchInject
$VMwareInstall
rmdir C:\Windows\Setup\Scripts /s /q
"@

        # Write SetupComplete.cmd contents to file in scratch directory
        $stream = [System.IO.StreamWriter] $SetupCompleteCMD
        $stream.Write(($SetupCompleteCMDContents -join "`r`n"))
        $stream.close()

        if($InjectPostPatch) {
            # Old
#             $PS1_Contents_v1 = @'
# $N = 'Skip TPM Check on Dynamic Update'
# $K = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vdsldr.exe'
# $C = "cmd /q $N /d/x/r>nul (erase /f/s/q %systemdrive%\`$windows.~bt\appraiserres.dll"
# $C+= '&md 11&cd 11&ren vd.exe vdsldr.exe&robocopy "../" "./" "vdsldr.exe"&ren vdsldr.exe vd.exe&start vd -Embedding)&rem;'
# $0 = New-Item $K
# Set-ItemProperty $K Debugger $C -force
# $0 = Set-ItemProperty HKLM:\SYSTEM\Setup\MoSetup 'AllowUpgradesWithUnsupportedTPMOrCPU' 1 -type dword -force -ea 0
# '@

            $PS1_Contents_v2 = @'
$N = 'Skip TPM Check on Dynamic Update'
$0 = Set-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 1 -type dword -force -ea 0
$C = "cmd /q $N /d/x/r>nul (erase /f/s/q %systemdrive%\`$windows.~bt\appraiserres.dll"
$C+= '&md 11&cd 11&ren vd.exe vdsldr.exe&robocopy "../" "./" "vdsldr.exe"&ren vdsldr.exe vd.exe&start vd -Embedding)&rem;'
$K = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vdsldr.exe'
$0 = New-Item $K -force -ea 0
Set-ItemProperty $K 'Debugger' $C -force
'@

            $scrFilepath = Join-Path -Path $Temp_PostSetupOperations_ScriptDirectory -ChildPath $PostPatchCMDFilename
            [byte[]]$E_BYTES = [convert]::FromBase64String($POST_PATCH_CMD_FILE_B64)
            [System.IO.File]::WriteAllBytes($scrFilepath, $E_BYTES)
            $ps1Filepath = Join-Path -Path $Temp_PostSetupOperations_ScriptDirectory -ChildPath $PostPatchPS1Filename
            $stream = [System.IO.StreamWriter] $ps1Filepath
            $stream.Write(($PS1_Contents_v2 -join "`r`n"))
            $stream.close()
        }
    }

    Function CopyPostSetupFiles ([string] $WIMFilePath, [string] $MountPath, [uint32] $WIMIndex) {
        $StartTime = $(get-date)

        Mount-WindowsImage -ImagePath $WIMFilePath -Index $WIMIndex -Path $MountPath
        Get-ChildItem $Temp_PostSetupOperations | Copy-Item -Destination $MountPath -Recurse -Force
        Dismount-WindowsImage -Path $MountPath -Save

        # Print time elapsed
        $elapsedTime = $(get-date) - $StartTime
        # Write-Host "Modifying edition index $WIMIndex took $(FormatTimespan $elapsedTime)" -ErrorAction SilentlyContinue -ForegroundColor Green
        PrintTimespan "Modifying edition index $WIMIndex took " $elapsedTime
    }

    Function InjectExtraPatches {
        AnnounceProgress_RunningExtraTasks
        Write-Host "Preparing to modify install.wim..."
        MakeDirectory $InstallWIMMountPath # Make our mount directory for install.wim...

        GeneratePostSetupFileStructure

        # Get information and list of its editions from install.wim
        Write-Host "Getting install.wim info..."
        $WIMEditions = Get-WindowsImage -ImagePath $InstallWIMFilePath

        if($WIMEditions.Count -gt 1) {
            # install.wim has more than one edition. Give the user the option to select editions to modify.
	    
	        # Create an empty list
	        $EditionList = @()
	    
            Write-Host "The install.wim image contains multiple editions. Select the editions you want to modify (editions not selected will be excluded from the new image)." -ForegroundColor Yellow
            Write-Host ""
	    
            # Go through and log editions
            foreach ($WIMedition in $WIMEditions) {
                $EditionList += ($WIMedition.ImageIndex.ToString() + ": " + $WIMedition.ImageName)
            }

            # Ask user to select what editions to modify
            $ModifyAll = $false

            $WIMEditionsCount = 1..$WIMEditions.Count
            $options = New-Object System.Collections.Generic.HashSet[int]

            if($GuiSelectMode) {
                $selected = $EditionList | Out-GridView -Title "Select editions to modify. Leave none selected to modify all." -OutputMode Multiple

                if($selected.Count -eq 0) {
                    #Write-Host "Modifying all..."
                    $ModifyAll = $true
                } else {
                    #Write-Host "Selected: $selected"
                }

                $Selection = foreach($item in $selected) {
                    try {
                        #[int]::Parse($item)
			            ($EditionList.indexOf($item) + 1)
                        #Write-Host $item
                    }
                    catch{}
                }
            } else {
                # Print editions from $EditionList
                $EditionList | ForEach-Object {"$PSItem"}

                Write-Host "" # Write empty line
                Write-Host "Enter a selection from 1 to $($WIMEditionsCount.Count), and press Enter to select that edition. When you're done, press Enter again to confirm your choices. If nothing is selected, all editions will be modified."
                do {
                    $userInput = Read-Host "($options)"
                    if ($userInput -eq "") {
                        continue
                    }
                    if ($userInput -notin $WIMEditionsCount) {
                        Write-Host "Invalid value entered."
                        continue
                    }
                    elseif ($userInput -in $options) {
                        do {
                            $inputF = Read-Host -Prompt "$userInput is already selected. Do you want to deselect it? [y/n]"
                            } while ($userInput -notcontains $inputF)
                        
                        if($inputF -eq "y") {
                            $options.Remove($userInput) | Out-Null
                        }
                        continue
                    }
                    else {
                        $options.Add($userInput) | Out-Null
                    }
                } while ($userInput -ne "")

                if($options.Count -eq 0) {
                    #Write-Host "Modifying all..."
                    $ModifyAll = $true
                }
                else {
                    Write-Host "Selected: $options"
                }

                $Selection = foreach($indexEntry in $options) {
                    try {
                        [int]::Parse($indexEntry)
                        #Write-Host $indexEntry
                    }
                    catch{}
                }
            }

            # Write-Host $Selection
            # $Selection = foreach($indexEntry in ($Multi_Options -Split ",")) {

            if(($Selection.Count -gt 1) -and ($Selection.Contains(0))) { # If individual editions were selected, check to see if a 0 exists, and remove it if the length of the list is larger than 1.
                $Selection = $Selection | Where-Object { $_ -ne 0 }
            }

            $Selection = $Selection | Select-Object -uniq # Remove duplicates from the array; not really necessary considering that the above selection method prevents that. We'll just keep it here for good measure.

            $Selection | ForEach-Object { $WIMEditions[$PSItem - 1].ImageName }

            # Get current time
            $TotalStartTime = $(get-date)

            if($ModifyAll) {
                Write-Host "Processing all"
                foreach ($edition in $WIMEditions) {
                    $PercentageComplete = GetPercentageFromRange $edition.ImageIndex 0 $WIMEditions.Count
                    Write-Progress -Activity "Modifying install.wim" -Status ("Modifying " + $edition.ImageName + " (" + $edition.ImageIndex.ToString() + "/" + $WIMEditions.Count.ToString() + ")") -PercentComplete $PercentageComplete
                    CopyPostSetupFiles $InstallWIMFilePath $InstallWIMMountPath $edition.ImageIndex
                }
                CleanWIM $InstallWIMFilePath $SelectedIndex
            }
            else
            {
                $EditionsToProcess = foreach ($edition in $WIMEditions) {
                    if ($Selection -contains $edition.ImageIndex) {
                        $edition
                    }
                }
                $EditionsToProcess
                Write-Host ""
                $CurrentIndex = 0
                foreach ($edition in $EditionsToProcess)
                {
                    $CurrentIndex++
                    $PercentageComplete = GetPercentageFromRange ($CurrentIndex - 1) 0 $EditionsToProcess.Count
                    Write-Progress -Activity "Modifying install.wim" -Status ("Modifying " + $edition.ImageName + " (" + $CurrentIndex.ToString() + "/" + $EditionsToProcess.Count.ToString() + ")") -PercentComplete $PercentageComplete
                    CopyPostSetupFiles $InstallWIMFilePath $InstallWIMMountPath $edition.ImageIndex
                    Start-Sleep 1
                }
                CleanWIM $InstallWIMFilePath $EditionsToProcess
            }

            # Print time elapsed
            $TotalElapsedTime = $(get-date) - $TotalStartTime
            # Write-Host "Done. Took $(FormatTimespan $TotalElapsedTime)" -ErrorAction SilentlyContinue -ForegroundColor Green
            PrintTimespan "Process complete. Took " $TotalElapsedTime
        }
        else { # There's only one edition in the WIM file.
            Write-Progress -Activity "Modifying install.wim" -Status ("Modifying " + $WIMEditions[0].ImageName + " (" + $WIMEditions[0].ImageIndex.ToString() + "/" + $WIMEditions.Count.ToString() + ")") -PercentComplete 0
            CopyPostSetupFiles $InstallWIMFilePath $InstallWIMMountPath $WIMEditions[0].ImageIndex
        }
    }

    # Function Sub_InjectVMwareTools ([string] $WIMFilePath, [string] $MountPath, [uint32] $WIMIndex, [string] $VMwareToolsSource) {
    #     # Scratch directory for VMware Tools
    # 
    #     # Prepare everything we need in the VMware Tools scratch directory.
    #     MakeDirectory $VMwareToolsScratchDir #... and our temporary directory for VMware Tools
    # 
    #     # Extract the VMware Tools ISO
    # 
    #     MakeDirectory $MountDir_Setup
    #     & $7ZipExecutable x $VMwareToolsISOPath ("-o" + (Join-Path -Path $VMwareToolsScratchDir -ChildPath $VMwareTempFolderName)) | Out-Null
    #     Copy-Item ($VMwareToolsSource + "\*") ($MountPath + "\") -Recurse -Force # | Out-Null
    # }
    # 
    # Function Sub_InjectPostPatch ([string] $WIMFilePath, [string] $MountPath, [uint32] $WIMIndex) {
    #     
    # }

    Function CleanWIM ([string] $WIMFilePath, $KeepEditions) {
        $OLD = $WIMFilePath + ".old"
        Move-Item $WIMFilePath $OLD -Force
        foreach ($edition in $KeepEditions)
        {
            Export-WindowsImage -SourceImagePath $OLD -SourceIndex $edition.ImageIndex -DestinationImagePath $WIMFilePath -CompressionType Max
        }
        Remove-Item $OLD -Force
    }

    Function CheckExists ($FilePath, $ItemName, $Description) {
        Write-Host "Checking if $ItemName exists..." -ForegroundColor Yellow -NoNewline
        $file_exists = Test-Path $FilePath
        if(!$file_exists)
        {
            Write-Host " no" -ForegroundColor Red
            Write-Host "$($ItemName): $Description does not exist" -ForegroundColor Red
            Exit
        }
        else {
            Write-Host " yes" -ForegroundColor Green
        }
    }

    Function PrepareSystemForUpgrade {
        if ($UpgradeMode) {
            Write-Host "Preparing system for upgrade..." -NoNewline

            $N = $PostPatch_WMISubscriptionName
            $null = Set-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 1 -type dword -force -ea 0
            $C = "cmd /q $N /d/x/r>nul (erase /f/s/q %systemdrive%\`$windows.~bt\appraiserres.dll"
            $C+= '&md 11&cd 11&ren vd.exe vdsldr.exe&robocopy "../" "./" "vdsldr.exe"&ren vdsldr.exe vd.exe&start vd -Embedding)&rem;'
            $K = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vdsldr.exe'
            $null = New-Item $K -force -ea 0
            $null = Set-ItemProperty $K 'Debugger' $C -force

            Write-Host " done" -ForegroundColor Green
            Write-Host "You can now mount the new Windows 11 ISO, and run setup.exe. However, you may need to reboot your systen for the changes to take effect."
        }
    }

    Function Undo_PrepareSystemForUpgrade {
        Write-Host "Undoing system changes..." -NoNewline

        $N = $PostPatch_WMISubscriptionName
        $null = Set-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 0 -type dword -force -ea 0
        $B = gwmi -Class __FilterToConsumerBinding -Namespace 'root\subscription' -Filter "Filter = ""__eventfilter.name='$N'""" -ea 0
        $C = gwmi -Class CommandLineEventConsumer -Namespace 'root\subscription' -Filter "Name='$N'" -ea 0
        $F = gwmi -Class __EventFilter -NameSpace 'root\subscription' -Filter "Name='$N'" -ea 0
        if ($B) { 
            $B | rwmi 
        }
        if ($C) { 
            $C | rwmi 
        } 
        if ($F) { 
            $F | rwmi 
        }
        $K = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vdsldr.exe'
        if (test-path $K) {
            Remove-Item $K -force -ea 0
        }

        Write-Host " done" -ForegroundColor Green
        Write-Host "You can now mount the new Windows 11 ISO, and run setup.exe. However, you may need to reboot your systen for the changes to take effect."
    }

#-----------------------------------------------------------------------------------------------------------------------
#------------------------------------------------Everything begins here-------------------------------------------------
#-----------------------------------------------------------------------------------------------------------------------

    Write-Host "Windows 11 Compatibility Check Bypass Tool"
    Write-Host "If you run into any issues, please don't hesitate to open an issue on the GitHub repository." -ForegroundColor Yellow

    Write-Host "Checking for administrative privleges..."
    if(!(AdminPrivleges)) {
        # powershell -noprofile -command "&{ start-process powershell -ArgumentList '-noprofile -file $ScriptExec -Win11Image $Source -DestinationImage $Destination' -verb RunAs}"
        Write-Host "This script requires administrative privleges to run." -ForegroundColor Red
        Exit
    }

    Set-Location -Path $ScriptDir # In case we aren't there already. It's a good idea for the PowerShell instance to be in the same directory as the commands we will be referencing.
    
    Write-Host "Getting required information..." -ForegroundColor Yellow

    # Write-Host "Checking if 7z exists..." -ForegroundColor Yellow -NoNewline
    # $7z_exists = Test-Path $7ZipExecutable
    # if(!$image_exists)
    # {
    #     Write-Host " no" -ForegroundColor Red
    #     Write-Error -Message "7z: Tool executable does not exist" -Category ObjectNotFound
    #     Exit
    # }
    # else {
    #     Write-Host " yes" -ForegroundColor Green
    # }
    # 
    # Write-Host "Checking if oscdimg exists..." -ForegroundColor Yellow -NoNewline
    # $image_exists = Test-Path $oscdimgExecutableFull
    # if(!$image_exists)
    # {
    #     Write-Host " no" -ForegroundColor Red
    #     Write-Error -Message "OSCDIMG: Tool executable does not exist" -Category ObjectNotFound
    #     Exit
    # }
    # else {
    #     Write-Host " yes" -ForegroundColor Green
    # }
    # 
    # Write-Host "Checking if ISO image exists..." -ForegroundColor Yellow -NoNewline
    # $image_exists = Test-Path $Source
    # if(!$image_exists)
    # {
    #     Write-Host " no" -ForegroundColor Red
    #     Write-Error -Message "Source: File does not exist" -Category ObjectNotFound
    #     Exit
    # }
    # else {
    #     Write-Host " yes" -ForegroundColor Green
    # }

    # Check to see if we have (and can access) everything we need
    CheckExists $7ZipExecutable "7z" "Tool executable"
    CheckExists $oscdimgExecutableFull "oscdimg" "Tool executable"
    CheckExists $Source "ISO image" "File"

    CleanupScratch # Just in case anything was left over from any previous runs as a result of an error
    MakeDirectory -Path $ScratchDir

    # Check for evidence that the image was previously modified. If there is any, give the user the option to either continue or stop.
    & $7ZipExecutable e $Source ("-o" + $ScratchDir) $sb_bypass_keyname -r | Out-Null
    if(Test-Path (Join-Path -Path $ScratchDir -ChildPath $sb_bypass_keyname))
    {
        Write-Host "Looks like this ISO has already been modified by this tool. Continuing with it is not recommended as it may have undesirable results."
        Alert_ImageModified
    }    
    Write-Progress -Activity "$ActivityName" -Status "Extracting image" -PercentComplete 0
    # Extract ISO contents to scratch directory
    & $7ZipExecutable x $Source ("-o" + $Win11ScratchDir) | Out-Null
    Write-Progress -Activity "$ActivityName" -Status "Mounting boot.wim" -PercentComplete 50

    # Make directory to mount WIM images to
    MakeDirectory -Path $WIMScratchDir

    if(-not $SkipReg) # If we're not skipping the boot.wim registry modifications, then...
    {
        $StartTime = $(get-date)
        # Mount boot.wim for editing
        Mount-WindowsImage -ImagePath $BootWIMFilePath -Index $BootWimImageIndex -Path $WIMScratchDir
        # Add the registry keys
        InjectRegistryKeys
        # Unmount WIM; save changes
        Write-Progress -Activity $ActivityName -Status "Dismounting boot.wim; saving changes..." -PercentComplete 60
        Dismount-WindowsImage -Path $WIMScratchDir -Save

        # Print time elapsed
        $elapsedTime = $(get-date) - $StartTime
        # Write-Host "boot.wim patched. Took $(FormatTimespan $elapsedTime)" -ErrorAction SilentlyContinue -ForegroundColor Green
        PrintTimespan "boot.wim patched. Took " $elapsedTime
    }

    # Check if we need to modify install.wim, and act accordingly
    if($InjectVMwareTools -or $InjectPostPatch) {
        InjectExtraPatches
    }

    # "Leave our mark" 
    # In other words, modify the contents of the final image in some sort of way to make it easily identifiable if a given ISO has already been modified by this tool.
    # In this case, let's copy the registry keys we used to the "sources" directory under the name defined in $sb_bypass_key
    [byte[]]$REGKEY_BYTES = [convert]::FromBase64String($REGISTRY_KEY_FILE_B64)
    [System.IO.File]::WriteAllBytes($sb_bypass_key, $REGKEY_BYTES)

    # Start creating the ISO image using OSCDIMG tool
    Write-Progress -Activity $ActivityName -Status "Creating ISO" -PercentComplete 95
    $OSCDIMG_ARGS = "-m -o -u2 -udfver102 -bootdata:2#p0,e,b$Win11ScratchDir\boot\etfsboot.com#pEF,e,b$Win11ScratchDir\efi\microsoft\boot\efisys.bin $Win11ScratchDir ""$Destination"""
    Start-Process -FilePath $oscdimgExecutable -WorkingDirectory $ScriptDir -ArgumentList $OSCDIMG_ARGS -Wait -WindowStyle $DefaultWindowStyle
    
    # Delete any leftovers
    Write-Progress -Activity $ActivityName -Status "Cleaning up" -PercentComplete 100
    CleanupScratch | Out-Null

    Write-Host "Image created." -ForegroundColor Green
    Write-Host $Destination

    Pause

    Set-Location -Path $OldLocation
}