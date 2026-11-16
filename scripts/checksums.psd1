# Pinned SHA256 checksums for every binary the installer downloads.
# Regenerate after bumping versions in install.ps1:
#
#   Get-FileHash <file> -Algorithm SHA256
#
# CC GUI v1.2.4
#   https://github.com/zhukunpenglinyutong/desktop-cc-gui/releases/download/v1.2.4/CC.GUI_1.2.4_x64-setup.exe
# CC Switch v4.0.32 portable
#   https://github.com/farion1231/cc-switch/releases/download/v4.0.32/CC-Switch-v4.0.32-Windows-Portable.zip
@{
    CcGuiInstaller   = '9c6b3fddff60e3bcc948ff12b683992a21b0a4d4fd89cced8049f444bcb64a6c'
    CcSwitchPortable = '9d3e72327f4ab085c302d5bbc969b1b64c1c90761c9bc25ceca01422e8ac04d8'
}
