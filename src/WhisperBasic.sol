// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/Context.sol";
import "suave-std/Transactions.sol";
import "suave-std/suavelib/Suave.sol";
import "suave-std/Gateway.sol";
import "suave-std/protocols/EthJsonRPC.sol";
import "suave-std/Random.sol";
import "suave-std/crypto/Secp256k1.sol";

interface ERC20 {
    function balanceOf(address) external view returns (uint256);
}

// TODO go sdk for input to prevent encoding issues
contract WhisperBasic is Suapp {
    address developer;

    // restrict sensitive functionality to the deployer of the smart contract
    modifier isDeveloper() {
        require(msg.sender == developer);
        _;
    }

    constructor () {
        developer = msg.sender;
    }

    event OffchainStatusEvent(uint256 code, string text);
    function onchainCallback() public emitOffchainLogs {}

    // KEY RELATED FUNCTIONALITY -------------------------------------------------------------------------------------------------------------------------------------
    event PrintSigningKeyEvent(string signing_key);
    event KeyUpdatedEvent(address addr);

    string public SIGNING_KEY = "KEY"; // TODO functionality of SIGNING_KEY variable??
    mapping (address => Suave.DataId) signingKeys; // mapping for confidentially stored private keys of addresses
    mapping (address => bool) signingKeyAvailable;

    modifier signingKeyStored(address owner) {
        require(signingKeyAvailable[owner], "No signing key stored for this address.");
        _;
    }

    function printSigningKey(address owner) public isDeveloper() signingKeyStored(owner) returns (bytes memory) {
        emit PrintSigningKeyEvent(string(Suave.confidentialRetrieve(signingKeys[owner], SIGNING_KEY)));
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function updateSigningKeyOnchain(address owner, Suave.DataId signingKeyRecord) public { // TODO update visibility such that only callable via offchain calls
        signingKeys[owner] = signingKeyRecord;
        signingKeyAvailable[owner] = true;
        emit KeyUpdatedEvent(owner);
    }

    function registerSigningKeyOffchain() public returns (bytes memory) {
        bytes memory keyData = Context.confidentialInputs(); // bytes in KeyData are retrieved decrypted
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        
        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "SIGNING_KEY"); // metadata for access control
        Suave.confidentialStore(record.id, SIGNING_KEY, keyData); // actual storing decrypted by TEE's private key: <key: record.id, value: keyData> in "db"

        return abi.encodeWithSelector(this.updateSigningKeyOnchain.selector, msg.sender, record.id);
    }

    function createKeyPairOffchain() internal returns (bytes memory) {
        string memory priv_key = Suave.privateKeyGen(Suave.CryptoSignature.SECP256);
        bytes memory keyData = bytes(priv_key);
        address addr = Secp256k1.deriveAddress(priv_key);

        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "SIGNING_KEY");
        Suave.confidentialStore(record.id, SIGNING_KEY, keyData);

        return abi.encodeWithSelector(this.updateSigningKeyOnchain.selector, addr, record.id);
    }

    // TRANSACTION RELATED FUNCTIONALITY -----------------------------------------------------------------------------------------------------------------------------
    event TxnSignature(bytes32 r, bytes32 s);
    event TxnRetrievalEvent(Transactions.EIP155 txn);

    function createHttpRequestForEndpoint(string memory endpointURL, bytes memory rlpEncodedTxn, uint256 chainId) internal view rpcStored(chainId) returns (Suave.HttpRequest memory) {
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";

        return Suave.HttpRequest({
            url: endpointURL,
            method: "POST",
            headers: headers,
            body: abi.encodePacked(
                '{"jsonrpc":"2.0","method":"eth_sendRawTransaction","params":["',
                toHexString(rlpEncodedTxn),
                '"],"id":',
                chainId,
                "}"
            ),
            withFlashbotsSignature: false,
            timeout: 7000
        });
    }

    // used to relay user singed transaction to the actual chain, if it suffies validation criteria
    function relayTransaction() public returns (bytes memory) {
        bytes memory rlpEncodedTxn = Context.confidentialInputs();
        Transactions.EIP155 memory txn = Transactions.decodeRLP_EIP155(rlpEncodedTxn);

        // TODO what should be validated here? what do we bookkeep in the smart contract and what do we read from ethereum?
        // TODO how to prevent double spending => nonce 3 singed to suave => gets relayed ==> user sends directly to eth another valid tx  with nonce 3 before suapp relayed
        require(txn.chainId == 11155111, "Blockchain not (yet) supported.");
        require(txn.value >= 1, "Value too low.");

        string memory rpcEndpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[txn.chainId], RPC));
        Suave.HttpRequest memory request = createHttpRequestForEndpoint(rpcEndpoint, rlpEncodedTxn, txn.chainId);
        bytes memory response = Suave.doHTTPRequest(request);
        emit HttpResponse(string(response));

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // used to issue new transactions in order to move funds after the auction has ended (nft-transfer, pay the auctioneer, losing bid returns)
    function makeTransaction(address fromAddress, address toAddress, uint256 value, bytes memory payload, uint256 chainId) signingKeyStored(fromAddress) internal returns (bytes memory) {
        bytes memory signingKey = Suave.confidentialRetrieve(signingKeys[fromAddress], SIGNING_KEY);

        // TODO can we assume that each address is only used for one outgoing tx? => nonce hardcoded to 1?
        uint256 nonce = getNonce(fromAddress, chainId);

        Transactions.EIP155Request memory txnWithToAddress = Transactions
            .EIP155Request({
                to: toAddress,
                gas: 1000000,           // TODO how to determine reasonable values for gas & gasPrice?
                gasPrice: 500,
                value: value,
                nonce: nonce,
                data: payload,
                chainId: chainId
            });

        Transactions.EIP155 memory txn = Transactions.signTxn(txnWithToAddress, string(signingKey));
        emit TxnSignature(txn.r, txn.s); // just for debugging purposes, TODO delete
        bytes memory rlpEncodedTxn = Transactions.encodeRLP(txn);

        string memory rpcEndpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        Suave.HttpRequest memory request = createHttpRequestForEndpoint(rpcEndpoint, rlpEncodedTxn, chainId);
        bytes memory response = Suave.doHTTPRequest(request);
        emit HttpResponse(string(response));

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // FETCHING RELATED FUNCTIONALITY --------------------------------------------------------------------------------------------------------------------------------
    event HttpResponse(string response);
    event RPCEndpoint(uint256 chainId, string endpointURL);
    event RPCEndpointUpdated(uint256 chainId);
    event Balance(address owner, uint256 value);
    event ERC20Balance(address coinAddr, address owner, uint256 value);
    event NonceCounter(address owner, uint256 value);

    string public RPC = "RPC";
    mapping (uint256 => Suave.DataId) rpcRecords;
    mapping (uint256 => bool) rpcAvailable;

    modifier rpcStored(uint256 chainId) {
        require(rpcAvailable[chainId], "No RPC-Endpoint available for this chain-ID.");
        _;
    }

    function updateRPCOnchain(uint256 chainId, Suave.DataId _rpcRecord) public {
        rpcRecords[chainId] = _rpcRecord;
        rpcAvailable[chainId] = true;
        emit RPCEndpointUpdated(chainId);
    }

    function printRPCEndpoint(uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        emit RPCEndpoint(chainId, bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC)));
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function registerRPCOffchain(uint256 chainId) public returns (bytes memory) {
        bytes memory rpcData = Context.confidentialInputs(); // use https://rpc.toliman.suave.flashbots.net // see https://suave-alpha.flashbots.net/toliman
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "rpc_endpoint" );
        Suave.confidentialStore(record.id, RPC, rpcData);

        return abi.encodeWithSelector(this.updateRPCOnchain.selector, chainId, record.id);
    }

    function registerRPCOffchain(uint256 chainId, string memory endpointURL) public returns (bytes memory) {
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(0, peekers, peekers, "rpc_endpoint" );
        Suave.confidentialStore(record.id, RPC, bytes(endpointURL));

        return abi.encodeWithSelector(this.updateRPCOnchain.selector, chainId, record.id);
    }

    // print/get NONCE
    function printNonce(address account) public returns (bytes memory) {
        return printNonce(account, 11155111);
    }

    function printNonce(address account, uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        uint256 nonce = getNonce(account, chainId);
        emit NonceCounter(account, nonce);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function getNonce(address account) internal returns (uint256) {
        return getNonce(account, 11155111);
    }

    function getNonce(address account, uint256 chainId) internal rpcStored(chainId) returns (uint256) {
        string memory endpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        EthJsonRPC jsonrpc = new EthJsonRPC(endpoint);
        return jsonrpc.nonce(account);
    }

    // print/get Balance
    function printBalance(address account) public returns (bytes memory) {
        return printBalance(account, 11155111);
    }

    function printBalance(address account, uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        uint256 balance = getBalance(account, chainId);
        emit Balance(account, balance);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function getBalance(address account) internal returns (uint256) {
        return getBalance(account, 11155111);
    }

    function getBalance(address account, uint256 chainId) internal rpcStored(chainId) returns (uint256) {
        string memory endpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        EthJsonRPC jsonrpc = new EthJsonRPC(endpoint);
        return jsonrpc.balance(account);
    }

    // print/get ERC20Balance
    function printERC20Balance(address coinAddr, address account) public returns (bytes memory) {
        return printERC20Balance(coinAddr, account, 11155111);
    }

    function printERC20Balance(address coinAddr, address account, uint256 chainId) public rpcStored(chainId) returns (bytes memory) {
        uint256 balance = getERC20Balance(coinAddr, account, chainId);
        emit ERC20Balance(coinAddr, account, balance);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function getERC20Balance(address coinAddr, address account) internal returns (uint256) {
        return getERC20Balance(coinAddr, account, 11155111);
    }

    function getERC20Balance(address coinAddr, address account, uint256 chainId) internal rpcStored(chainId) returns (uint256) {
        string memory endpoint = bytesToString(Suave.confidentialRetrieve(rpcRecords[chainId], RPC));
        Gateway gateway = new Gateway(endpoint, coinAddr);
        ERC20 token = ERC20(address(gateway));
        return token.balanceOf(account);
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
