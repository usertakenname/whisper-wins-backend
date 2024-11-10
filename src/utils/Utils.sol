// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

library Utils {
    function bytesToString(
        bytes memory data
    ) internal pure returns (string memory) {
        uint256 length = data.length;
        bytes memory chars = new bytes(length);

        for (uint i = 0; i < length; i++) {
            chars[i] = data[i];
        }

        return string(chars);
    }

    function isEqual(
        bytes memory a,
        bytes memory b
    ) internal pure returns (bool) {
        if (a.length != b.length) {
            return false;
        }

        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) {
                return false;
            }
        }

        return true;
    }

    function toHexString(
        bytes memory data
    ) internal pure returns (string memory) {
        bytes memory hexAlphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = hexAlphabet[uint256(uint8(data[i] >> 4))];
            str[3 + i * 2] = hexAlphabet[uint256(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }
}
