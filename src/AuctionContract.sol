// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/crypto/Secp256k1.sol";

contract AuctionContract is Suapp {
    //TODO: Bids, Type of auction (create superclass), deadline etc.
    address auctioneer;
    string public SIGNING_KEY = "KEY"; // TODO functionality of SIGNING_KEY variable??

    // restrict sensitive functionality to the deployer of the smart contract
    modifier isOwner() {
        require(msg.sender == auctioneer);
        _;
    }

    constructor() {
        auctioneer = msg.sender;
    }

    function getSigningKeyRecords() confidential() internal returns (bytes memory){

    }

    mapping(string => Suave.DataId) signingKeyRecords; // deprecated
    mapping(address => Suave.DataId) signingKeys; // mapping for confidentially stored private keys of addresses
    mapping(address => bool) signingKeyAvailable;
    mapping(address => address) bidderToWallet; // TODO: put into confidential store?

    function onchainCallback() public emitOffchainLogs {}

    event EncryptedAddressEvent(address encryptedAddress);
    event PrintSigningKeyEvent(string mes, string signKey);

    modifier signingKeyStored(address msgSender) {
        require(
            signingKeyAvailable[bidderToWallet[msgSender]],
            "No signing key stored for this address."
        );
        _;
    }

    /*
    * emits signingKey for @param wallet address; signing key must exist
    * TODO: only for testing; make owner only afterwards & adapt retrieveKey() method
    */
    function retrieveKey(address wallet)
        external
        confidential
        signingKeyStored(wallet)
        returns (bytes memory)
    {
        emit PrintSigningKeyEvent(
            "Retrieving signing key",
            string(
                Suave.confidentialRetrieve(
                    signingKeys[bidderToWallet[wallet]],
                    SIGNING_KEY
                )
            )
        );
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    /*
    * emits signingKey for message sender; (sender must have called createKeyPairOffchain() before)
    */
    function retrieveKey()
        external
        confidential
        signingKeyStored(msg.sender)
        returns (bytes memory)
    {
        return this.retrieveKey(msg.sender);
    }

    function createKeyPairOffchain()
        external
        confidential
        returns (bytes memory)
    {
        if (signingKeyAvailable[bidderToWallet[msg.sender]]) {
            emit PrintSigningKeyEvent(
                "Signed Key already exists; Skip creating a new one.",
                string(
                    Suave.confidentialRetrieve(
                        signingKeys[bidderToWallet[msg.sender]],
                        SIGNING_KEY
                    )
                )
            );
            return abi.encodeWithSelector(this.onchainCallback.selector);
        } else {
            string memory priv_key = Suave.privateKeyGen(
                Suave.CryptoSignature.SECP256
            );
            bytes memory keyData = bytes(priv_key);
            address addr = Secp256k1.deriveAddress(priv_key);

            address[] memory peekers = new address[](1);
            peekers[0] = address(this);

            Suave.DataRecord memory record = Suave.newDataRecord(
                0,
                peekers,
                peekers,
                "SIGNING_KEY"
            );
            Suave.confidentialStore(record.id, SIGNING_KEY, keyData);
            emit EncryptedAddressEvent(addr); // TODO: encrypt address with msg.senders public key
            return
                abi.encodeWithSelector(
                    this.updateSigningKeyOnchain.selector,
                    addr,
                    record.id
                );
        }
    }

    function updateSigningKeyOnchain(
        address owner,
        Suave.DataId signingKeyRecord
    ) external emitOffchainLogs {
        // TODO update visibility such that only callable via offchain calls
        signingKeys[owner] = signingKeyRecord;
        signingKeyAvailable[owner] = true;
        bidderToWallet[msg.sender] = owner;
    }

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

    function toUint(bytes memory s) public pure returns (uint256) {
        uint256 number = 0;

        for (uint256 i = 0; i < s.length; i++) {
            require(s[i] >= 0x30 && s[i] <= 0x39, "Invalid character");
            number = number * 10 + (uint256(uint8(s[i])) - 48);
        }

        return number;
    }
}
