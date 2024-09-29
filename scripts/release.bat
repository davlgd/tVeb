@echo off

Set "FILE_NAME=tVeb-windows-x86_64.exe"
Set "BIN_FOLDER=bin"
mkdir %BIN_FOLDER%

echo "Building tVeb for Windows and x86_64 architecture as %FILE_NAME%..."
v\v -prod . -o "%BIN_FOLDER%\%FILE_NAME%"

CertUtil -hashfile "%BIN_FOLDER%\%FILE_NAME%" SHA256 > "%BIN_FOLDER%\%FILE_NAME%.sha256"
CertUtil -hashfile "%BIN_FOLDER%\%FILE_NAME%" SHA512 > "%BIN_FOLDER%\%FILE_NAME%.sha512"
