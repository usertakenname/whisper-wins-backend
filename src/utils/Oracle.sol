// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/Context.sol";
import "suave-std/suavelib/Suave.sol";
import "solady/src/utils/LibString.sol";
import "solady/src/utils/JSONParserLib.sol";
import "suave-std/crypto/Secp256k1.sol";
import "suave-std/Transactions.sol";

interface SealedAuction {
    function registerFinalBlockNumber(
        uint256 _finalBlockNr
    ) external returns (bytes memory);
    function confirmNFTowner(address _NFTowner) external returns (bytes memory);
    function refuteWinnerCallback(
        address checkedAddress,
        uint256 balance
    ) external returns (bytes memory);
    function finaliseStartAuction() external view returns (bytes memory);
}

contract Oracle is Suapp {
    address public owner;
    uint256 public chainID;
    Suave.DataId rpcEndpoint;
    string RPC = "RPC";
    string public SERVER_URL = "http://localhost:8001";
    string public BASE_API_URL = "http://localhost:8555"; // TODO: remove
    string public BASE_ALCHEMY_URL = "https://eth-sepolia.g.alchemy.com/v2/";
    string public PRIVATE_KEYS = "KEY";

    constructor(uint256 _chainID) {
        owner = msg.sender;
        chainID = _chainID;
    }

    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "You are not the owner of this contract and can not modify it"
        );
        _;
    }

    modifier rpcStored() {
        bytes memory NULL = hex"00000000000000000000000000000000";
        require(
            (keccak256(abi.encodePacked((rpcEndpoint))) !=
                keccak256(abi.encodePacked((NULL)))),
            "No RPC Endpoint registered yet"
        );
        _;
    }

    // =============================================================
    //                  FUNCTIONALITY: REGISTER RPC ENDPOINT
    // =============================================================

    /**
     * @notice Registers an off-chain API key in the Suave Confidential Storage.
     * @dev Only confidentially callable by the owner of the contract with confidential input.
     * @custom:confidential-input API_KEY Confidential input is the API key.
     * @return Nothing.
     */
    function registerApiKeyOffchain()
        external
        onlyOwner
        confidential
        returns (bytes memory)
    {
        // Retrieve confidential input data (API key )
        bytes memory rpcData = Context.confidentialInputs();
        address[] memory peekers = new address[](1);
        peekers[0] = address(this); // The current contract is the only allowed peeker

        Suave.DataRecord memory record = Suave.newDataRecord(
            0,
            peekers, // Addresses allowed to read the data
            peekers, // Addresses allowed to manage the data
            "rpc_endpoint" // Label or identifier for the data
        );

        Suave.confidentialStore(record.id, RPC, rpcData);
        return
            abi.encodeWithSelector(
                this.registerApiKeyOnchain.selector,
                record.id
            );
    }

    /**
     * @notice Registers an API key onchain.
     * @dev Function should only be called by registerApiKeyOffchain, not externally. (Can not be made internal! TODO: Suave currently offers no alternatives)
     * @param _rpcRecord The Suave DataID to look up the API Key in the Confidential Storage.
     */
    function registerApiKeyOnchain(
        Suave.DataId _rpcRecord // Identifier of the confidential data record
    ) public onlyOwner emitOffchainLogs confidential {
        // Update the contract's stored RPC endpoint with the new record ID
        rpcEndpoint = _rpcRecord;
    }

    /**
     * @notice Retrieves the full RPC endpoint URL by concatenating the base URL with the stored confidential endpoint.
     * @dev Combines the `API_URL` constant with confidentially retrieved data.
     */
    function getRPCEndpointURL() internal returns (string memory) {
        return
            // Concatenate the base API URL with the confidentially stored endpoint
            string.concat(
                BASE_ALCHEMY_URL, // Base API URL
                string(Suave.confidentialRetrieve(rpcEndpoint, RPC)) // Confidential endpoint data
            );
    }

    // =============================================================
    //                  FUNCTIONALITY: RPC Calls
    // =============================================================
    function getHeaders() internal pure returns (string[] memory) {
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";
        return headers;
    }

    function makePostRPCCall(
        bytes memory _body
    ) internal rpcStored returns (bytes memory response) {
        Suave.HttpRequest memory request = Suave.HttpRequest({
            url: getRPCEndpointURL(),
            method: "POST",
            headers: getHeaders(),
            body: _body,
            withFlashbotsSignature: false,
            timeout: 7000
        });
        return Suave.doHTTPRequest(request);
    }
    //TODO: remove
    function makePostRPCCallTest(
        bytes memory _body
    ) internal rpcStored returns (bytes memory response) {
        Suave.HttpRequest memory request = Suave.HttpRequest({
            url: BASE_API_URL,
            method: "POST",
            headers: getHeaders(),
            body: _body,
            withFlashbotsSignature: false,
            timeout: 7000
        });
        return Suave.doHTTPRequest(request);
    }

    function makeGetRPCCall(
        string memory path
    ) internal rpcStored returns (bytes memory response) {
        response = Suave.doHTTPRequest(
            Suave.HttpRequest({
                url: string.concat(getRPCEndpointURL(), path),
                method: "GET",
                headers: getHeaders(),
                body: "",
                withFlashbotsSignature: false,
                timeout: 7000
            })
        );
    }

    /**
     * @notice Gets the current Ethereum Block Number.
     * @custom:return blockNumber Current Ethereum Block Number.
     */
    function getEthBlockNumber() external confidential returns (bytes memory) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_blockNumber", "params": [], "id": "',
            toString(chainID),
            '"}'
        );
        bytes memory response = makePostRPCCall(_body);
        uint256 blockNumber = JSONParserLib.parseUintFromHex(
            trimQuotes(JSONParserLib.value(getJSONField(response, "result")))
        );
        SealedAuction sealedAuction = SealedAuction(msg.sender);
        return sealedAuction.registerFinalBlockNumber(blockNumber); // call the onchain function of sealed auction
    }

    function onchainCallback() public emitOffchainLogs {}

    function getNFTOwnedBy(
        address _nftContract,
        uint256 _tokenId
    ) external returns (bytes memory) {
        string memory path = string.concat(
            "/getOwnersForToken?contractAddress=",
            toHexString(abi.encodePacked(_nftContract)),
            "&tokenId=",
            toString(_tokenId)
        );
        bytes memory response = makeGetRPCCall(path);
        address NFTowner = address(
            uint160(
                parseUintFromHex(
                    stripQuotes(
                        JSONParserLib.value(
                            JSONParserLib.at(
                                getJSONField(response, "owners"),
                                0
                            )
                        )
                    )
                )
            )
        );
        SealedAuction sealedAuction = SealedAuction(msg.sender);
        return sealedAuction.confirmNFTowner(NFTowner);
    }

    function registerContract(address contract_address, uint256 end_time) external returns (bytes memory) {
        bytes memory response = Suave.doHTTPRequest(
            Suave.HttpRequest({
                url: string.concat(SERVER_URL, "/register-contract" ),
                method: "POST",
                headers: getHeaders(),
                body: abi.encodePacked(
                        '{"end_timestamp": ', end_time, '"address": "', toHexString(abi.encodePacked(contract_address)), '"}'
                    ),
                withFlashbotsSignature: false,
                timeout: 7000
            })
        );
        SealedAuction sealedAuction = SealedAuction(msg.sender);
        return sealedAuction.finaliseStartAuction();
    }

    function getGasPrice() internal returns (uint256 gasPrice) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_gasPrice", "params": [], "id": ',
            toString(chainID),
            "}"
        );
        bytes memory response = makePostRPCCallTest(_body); //TODO:

        // Hex-number answer in json["result"], eg: {"jsonrpc":"2.0","id":11155111,"result":"0x2138251e3"}
        gasPrice = JSONParserLib.parseUintFromHex(
            stripQuotes(JSONParserLib.value(getJSONField(response, "result")))
        );
    }

    function getBalanceAtBlockExternal(
        address l1Address,
        uint256 finalETHBlock
    ) external confidential returns (bytes memory) {
        uint256 balance = getBalanceAtBlock(l1Address, finalETHBlock);
        SealedAuction sealedAuction = SealedAuction(msg.sender);
        return sealedAuction.refuteWinnerCallback(l1Address, balance);
    }

    event testEvent(string t);

    function getBalanceAtBlock(
        address l1Address,
        uint256 finalETHBlock
    ) internal confidential returns (uint256 balance) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_getProof", "params": ["',
            toHexString(abi.encodePacked(l1Address)),
            '",[],"',
            //LibString.toMinimalHexString(finalETHBlock), // change to this
            "latest",
            '"], "id": "',
            toString(chainID),
            '"}'
        );
        bytes memory response = makePostRPCCallTest(_body); // TODO: change to real method
        balance = JSONParserLib.parseUintFromHex(
            stripQuotes(
                JSONParserLib.value(
                    JSONParserLib.at(
                        getJSONField(response, "result"),
                        '"balance"'
                    )
                )
            )
        );
    }

    // msgSender is Suave msg sender, L1ReturnAddress is the address to return
    function transfer(
        address msgSender,
        address returnAddress,
        uint256 finalETHBlock,
        Suave.DataId suaveDataID
    ) external returns (bytes memory) {
        bytes memory privateL1Key = Suave.confidentialRetrieve(
            suaveDataID,
            PRIVATE_KEYS
        );
        address publicL1Address = Secp256k1.deriveAddress(string(privateL1Key));
        uint256 gasPrice = getGasPrice() * 2;
        uint256 value = getBalanceAtBlock(publicL1Address, finalETHBlock);
        if (value >= 21000 * gasPrice) {
            makeTransaction(
                returnAddress,
                gasPrice,
                value - (21000 * gasPrice),
                "",
                suaveDataID
            );
        } else {
            emit FundsTooLessToPayout(publicL1Address);
        }

        SealedAuction sealedAuction = SealedAuction(msg.sender);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    event FundsTooLessToPayout(address addressToPayout);

    // used to issue new transactions in order to move funds after the auction has ended (pay the auctioneer, losing bid returns)
    function makeTransaction(
        address toAddress,
        uint256 gasPrice,
        uint256 value,
        bytes memory payload,
        Suave.DataId suaveDataID
    ) internal rpcStored returns (bytes memory) {
        bytes memory privateL1Key = Suave.confidentialRetrieve(
            suaveDataID,
            PRIVATE_KEYS
        );
        address fromAddress = Secp256k1.deriveAddress(string(privateL1Key));
        uint256 nonce = getNonce(fromAddress);

        Transactions.EIP155Request memory txnWithToAddress = Transactions
            .EIP155Request({
                to: toAddress,
                gas: 21000,
                gasPrice: gasPrice,
                value: value,
                nonce: nonce,
                data: payload,
                chainId: chainID
            });

        Transactions.EIP155 memory txn = Transactions.signTxn(
            txnWithToAddress,
            string(privateL1Key)
        );
        bytes memory rlpEncodedTxn = Transactions.encodeRLP(txn);

        createRawTxHttpRequest(rlpEncodedTxn);

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    function getNonce(
        address account
    ) internal rpcStored returns (uint256 nonce) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_getTransactionCount", "params": ["',
            toHexString(abi.encodePacked(account)),
            '", "latest" ], "id": "',
            toString(chainID),
            '"}'
        );
        bytes memory response = makePostRPCCallTest(_body); //TODO: change to real rpc
        nonce = JSONParserLib.parseUintFromHex(
            trimQuotes(JSONParserLib.value(getJSONField(response, "result")))
        );
    }

    function createRawTxHttpRequest(
        bytes memory rlpEncodedTxn
    ) internal rpcStored {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_sendRawTransaction", "params": ["',
            toHexString(rlpEncodedTxn),
            '"], "id": "',
            toString(chainID),
            '"}'
        );
        bytes memory response = makePostRPCCallTest(_body); //TODO: change to real rpc
    }

    // =============================================================
    //                  HELPER FUNCTIONALITY
    // =============================================================

    /**
     * @notice Trims the quotes of the input.
     * @param input string containing " at the beginning and end.
     * @return result string without the " at the beginning and end.
     */
    function trimQuotes(
        string memory input
    ) private pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        require(
            inputBytes.length >= 2 &&
                inputBytes[0] == '"' &&
                inputBytes[inputBytes.length - 1] == '"',
            "Invalid input"
        );

        bytes memory result = new bytes(inputBytes.length - 2);

        for (uint256 i = 1; i < inputBytes.length - 1; i++) {
            result[i - 1] = inputBytes[i];
        }

        return string(result);
    }

    /**
     * @notice Return json field of input.
     * @param json json in bytes format.
     * @param key field to return.
     * @return keyItem JSON item .
     */
    function getJSONField(
        bytes memory json,
        string memory key
    ) internal pure returns (JSONParserLib.Item memory keyItem) {
        JSONParserLib.Item memory item = JSONParserLib.parse(string(json));
        JSONParserLib.Item memory err = JSONParserLib.at(item, '"error"');
        if (!JSONParserLib.isUndefined(err)) {
            revert(JSONParserLib.value(err));
        }
        return JSONParserLib.at(item, string.concat('"', key, '"'));
    }

    /**
     * @notice convert uint256 to String.
     */
    function toString(uint256 value) internal pure returns (string memory str) {
        return LibString.toString(value);
    }

    /**
     * @notice convert bytes to Hex String.
     */
    function toHexString(
        bytes memory data
    ) internal pure returns (string memory) {
        return LibString.toHexString(data);
    }

    function parseUintFromHex(
        string memory input
    ) internal pure returns (uint256) {
        return JSONParserLib.parseUintFromHex(input);
    }

    //method in EthJsonRPC
    function stripQuotes(
        string memory input
    ) internal pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        bytes memory result = new bytes(inputBytes.length - 2);

        for (uint256 i = 1; i < inputBytes.length - 1; i++) {
            result[i - 1] = inputBytes[i];
        }

        return string(result);
    }
}
