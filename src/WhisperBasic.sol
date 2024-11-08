// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/Context.sol";
import "suave-std/Transactions.sol";
import "suave-std/suavelib/Suave.sol";
import "suave-std/Gateway.sol";
import "suave-std/protocols/EthJsonRPC.sol";

interface ERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract WhisperBasic is Suapp {
    event OffchainStatusEvent(uint256 code, string text);
    function onchainCallback() public emitOffchainLogs {}


    // KEY RELATED FUNCTIONALITY -------------------------------------------------------------------------------------------------------------------------------------
    event PrintPrivateKeyEvent(string private_key);

    Suave.DataId signingKeyRecord;                                      // id (= key) of current private key record
    string public PRIVATE_KEY = "KEY";                                  // TODO functionality of PRIVATE_KEY variable?? bad naming??

    function printPrivateKey() public {
        emit PrintPrivateKeyEvent(
            string(Suave.confidentialRetrieve(signingKeyRecord, PRIVATE_KEY))
        );
    }

    function updateKeyOnchain(Suave.DataId _signingKeyRecord) public {
        signingKeyRecord = _signingKeyRecord;
    }

    function registerPrivateKeyOffchain() public returns (bytes memory) {
        bytes memory keyData = Context.confidentialInputs();            // bytes in KeyData are decrypted during processing
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "private_key"); // kind of metadata for access control
        Suave.confidentialStore(record.id, PRIVATE_KEY, keyData);       // actual storing decrypted by TEE's private key: <key: record.id, value: keyData> in "db" TODO: role of PRIVATE_KEY variable???

        return abi.encodeWithSelector(this.updateKeyOnchain.selector, record.id);
    }

    function createPrivateKeyOffchain() public returns (bytes memory) {
        // TODO: create out of thin air needed?? whats the use case for that?
    }


    // TRANSACTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    event TxnSignature(bytes32 r, bytes32 s);
    event TxnRetrievalEvent(Transactions.EIP155 txn);

    // untested
    function retrieveTransaction() public returns (bytes memory) {
        bytes memory rlpEncodedTxn = Context.confidentialInputs();
        Transactions.EIP155 memory txn = Transactions.decodeRLP_EIP155(rlpEncodedTxn);

        emit TxnRetrievalEvent(txn);

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // untested
    function makeTransaction(address toAddress, uint256 value, bytes memory payload, uint256 chainId) public returns (bytes memory) {
        bytes memory signingKey = Suave.confidentialRetrieve(signingKeyRecord, PRIVATE_KEY);

        Transactions.EIP155Request memory txnWithToAddress = Transactions
            .EIP155Request({
                to: toAddress,
                gas: 1000000,
                gasPrice: 500,
                value: value,
                nonce: 1,
                data: payload,
                chainId: chainId
            });

        Transactions.EIP155 memory txn = Transactions.signTxn(txnWithToAddress, string(signingKey));
        emit TxnSignature(txn.r, txn.s);
        bytes memory rlpEncodedTxn = Transactions.encodeRLP(txn);
        
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";

        Suave.HttpRequest memory request = Suave.HttpRequest({
            url: string(Suave.confidentialRetrieve(rpcRecord, RPC)),
            method: "POST",
            headers: headers,
            body: abi.encodePacked(
                '{"jsonrpc":"2.0","method":"eth_sendRawTransaction","params":["',
                toHexString(rlpEncodedTxn),
                '"],"id":',chainId,'}'
            ),
            withFlashbotsSignature: false,
            timeout: 7000
        });

        bytes memory response = Suave.doHTTPRequest(request);
        emit HttpAnswer(string(response));


        return abi.encodeWithSelector(this.onchainCallback.selector);
    }


    // FETCHING RELATED FUNCTIONALITY --------------------------------------------------------------------------------------------------------------------------------
    event HttpAnswer(string answer);
    event Balance(address owner, uint256 value);
    event NonceCounter(address owener, uint256 value);

    Suave.DataId rpcRecord;
    string public RPC = "RPC";

    function updateRPCOnchain(Suave.DataId _rpcRecord) public {
        rpcRecord = _rpcRecord;
    }

    function registerRPCOffchain() public returns (bytes memory) {
        bytes memory rpcData = Context.confidentialInputs();                  // TODO: how to find a valid rpc link (with key???)

        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "rpc_endpoint");
        Suave.confidentialStore(record.id, RPC, rpcData);

        return abi.encodeWithSelector(this.updateRPCOnchain.selector, record.id);
    }

    // tested
    function getNonce(address account) external returns (bytes memory) {
        bytes memory rpcData = Suave.confidentialRetrieve(rpcRecord, RPC);
        string memory endpoint = bytesToString(rpcData);

        EthJsonRPC jsonrpc = new EthJsonRPC(endpoint);
        uint256 nonce = jsonrpc.nonce(account);
        
        emit NonceCounter(account, nonce);

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // tested
    function getERC20Balance(address contractAddr, address account) external returns (bytes memory) {
        bytes memory rpcData = Suave.confidentialRetrieve(rpcRecord, RPC);
        string memory endpoint = bytesToString(rpcData);

        Gateway gateway = new Gateway(endpoint, contractAddr);
        ERC20 token = ERC20(address(gateway));
        uint256 balance = token.balanceOf(account);

        emit Balance(account, balance);

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }


    // HELPER FUNCTIONALITY ------------------------------------------------------------------------------------------------------------------------------------------
    function bytesToString(bytes memory data) internal pure returns (string memory) {
        uint256 length = data.length;
        bytes memory chars = new bytes(length);

        for (uint i = 0; i < length; i++) {
            chars[i] = data[i];
        }

        return string(chars);
    }

    function toHexString(bytes memory data) internal pure returns (string memory) {
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
