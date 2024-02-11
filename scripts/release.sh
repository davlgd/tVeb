#!/bin/bash

OS_NAME=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m | tr '[:upper:]' '[:lower:]')
FILE_NAME="tws-$OS_NAME-$ARCH"
BIN_FOLDER="bin"

echo "Building tws for ${OS_NAME} and ${ARCH} architecture as ${FILE_NAME}..."
mkdir -p ${BIN_FOLDER} && v/v -prod . -o "${BIN_FOLDER}/${FILE_NAME}"

(shasum -a 512 "${BIN_FOLDER}/${FILE_NAME}" 2>/dev/null || sha512sum ${FILE_NAME}) > "${BIN_FOLDER}/${FILE_NAME}.sha512"
(shasum -a 256 "${BIN_FOLDER}/${FILE_NAME}" 2>/dev/null || sha256sum ${FILE_NAME}) > "${BIN_FOLDER}/${FILE_NAME}.sha256"
