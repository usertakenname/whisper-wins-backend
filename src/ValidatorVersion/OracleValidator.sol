// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/Context.sol";
import "suave-std/suavelib/Suave.sol";
import "solady/src/utils/LibString.sol";
import "solady/src/utils/JSONParserLib.sol";
import "suave-std/crypto/Secp256k1.sol";
import "suave-std/Transactions.sol";

interface SealedAuctionValidator {
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

contract OracleValidator is Suapp {
    address public owner;
    uint256 public chainID;
    string PRIVATE_KEYS = "KEY";
    string RPC = "RPC";
    Suave.DataId alchemyEndpoint;
    Suave.DataId etherscanEndpoint;
    string VALIDATOR_URL = "http://localhost:8001";
    string BASE_API_URL = "http://localhost:8555"; // TODO for production: remove
    string public BASE_ALCHEMY_URL = "https://eth-sepolia.g.alchemy.com/v2/";
    string public BASE_SEPOLIA_ETHERSCAN_URL =
        "https://api-sepolia.etherscan.io/api";

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

    function onchainCallback() public emitOffchainLogs {}

    // =============================================================
    //        FUNCTIONALITY: REGISTER API-KEYS FOR RPC ENDPOINTS
    // =============================================================

    modifier alchemyKeyStored() {
        bytes memory NULL = hex"00000000000000000000000000000000";
        require(
            (keccak256(abi.encodePacked((alchemyEndpoint))) !=
                keccak256(abi.encodePacked((NULL)))),
            "No RPC Endpoint registered yet"
        );
        _;
    }

    modifier etherscanKeyStored() {
        bytes memory NULL = hex"00000000000000000000000000000000";
        require(
            (keccak256(abi.encodePacked((etherscanEndpoint))) !=
                keccak256(abi.encodePacked((NULL)))),
            "No etherscan Endpoint registered yet"
        );
        _;
    }

    /**
     * @notice Registers off-chain an API key in the Suave Confidential Storage.
     * @dev Only confidentially callable by the owner of the contract with confidential input.
     * @custom:confidential-input API_KEY Confidential input is the API key.
     * @return Nothing.
     */
    function registerApiKeyOffchain(
        string memory rpcName
    ) external onlyOwner confidential returns (bytes memory) {
        bytes memory rpcData = Context.confidentialInputs();
        address[] memory peekers = new address[](1);
        peekers[0] = address(this);

        Suave.DataRecord memory record = Suave.newDataRecord(
            0,
            peekers,
            peekers,
            RPC
        );

        Suave.confidentialStore(record.id, RPC, rpcData);
        return
            abi.encodeWithSelector(
                this.registerApiKeyOnchain.selector,
                rpcName,
                record.id
            );
    }

    /**
     * @notice Callback for API key registration.
     * @param _rpcRecord The Suave DataID to look up the API Key in the Confidential Storage.
     */
    function registerApiKeyOnchain(
        string memory rpcName,
        Suave.DataId _rpcRecord
    ) public onlyOwner emitOffchainLogs confidential {
        if (keccak256(bytes(rpcName)) == keccak256(bytes("alchemy"))) {
            alchemyEndpoint = _rpcRecord;
        } else if (keccak256(bytes(rpcName)) == keccak256(bytes("etherscan"))) {
            etherscanEndpoint = _rpcRecord;
        } else {
            revert(
                'The provided RPC-Name is neither "alchemy" nor "etherscan"'
            );
        }
    }

    /**
     * @notice Retrieves the full RPC endpoint URL by concatenating the base URL with the stored confidential endpoint.
     * @dev Combines the `API_URL` constant with confidentially retrieved data.
     */
    function getRPCEndpointURL() internal returns (string memory) {
        return
            string.concat(
                BASE_ALCHEMY_URL,
                string(Suave.confidentialRetrieve(alchemyEndpoint, RPC))
            );
    }

    // =============================================================
    //           FUNCTIONALITY: "API" FOR SEALED AUCTIONS
    // =============================================================

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
                    trimQuotes(
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
        SealedAuctionValidator sealedAuction = SealedAuctionValidator(
            msg.sender
        );
        return sealedAuction.confirmNFTowner(NFTowner);
    }

    function registerContractAtValidator(
        address contract_address,
        uint256 end_time
    ) external returns (bytes memory) {
        Suave.doHTTPRequest(
            Suave.HttpRequest({
                url: string.concat(VALIDATOR_URL, "/register-contract"),
                method: "POST",
                headers: getHeaders(),
                body: abi.encodePacked(
                    '{"end_timestamp": ',
                    toString(end_time),
                    ', "address": "',
                    toHexString(abi.encodePacked(contract_address)),
                    '"}'
                ),
                withFlashbotsSignature: false,
                timeout: 7000
            })
        );
        SealedAuctionValidator sealedAuction = SealedAuctionValidator(
            msg.sender
        );
        return sealedAuction.finaliseStartAuction();
    }

    function transferNFT(
        address from,
        address to,
        address nftContract,
        uint256 tokenId,
        Suave.DataId suaveDataID
    ) public returns (bytes memory) {
        uint256 gasPrice = getGasPrice() * 2;
        bytes memory payload = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            from,
            to,
            tokenId
        );
        uint256 value = getBalance(from);
        if (value >= 81000 * gasPrice) {
            return
                makeTransaction(
                    nftContract,
                    80000,
                    gasPrice,
                    0,
                    payload,
                    suaveDataID
                );
        } else {
            revert(
                string.concat(
                    "The account ",
                    toHexString(abi.encodePacked(from)),
                    " with balance: ",
                    toString(value),
                    " does not have enough funds to transfer the NFT"
                )
            );
        }
    }

    function transferETH(
        address returnAddress,
        Suave.DataId suaveDataID
    ) external returns (bytes memory) {
        bytes memory privateL1Key = Suave.confidentialRetrieve(
            suaveDataID,
            PRIVATE_KEYS
        );
        address publicL1Address = Secp256k1.deriveAddress(string(privateL1Key));
        uint256 gasPrice = getGasPrice() * 2;
        uint256 value = getBalance(publicL1Address);
        if (value >= 21000 * gasPrice) {
            makeTransaction(
                returnAddress,
                21000,
                gasPrice,
                value - (21000 * gasPrice),
                "",
                suaveDataID
            );
            return abi.encodeWithSelector(this.onchainCallback.selector);
        } else {
            revert(
                string.concat(
                    "The account ",
                    toHexString(abi.encodePacked(publicL1Address)),
                    " with balance: ",
                    toString(value),
                    " does not have enough funds to transfer ETH"
                )
            );
        }
    }

    function getBalanceAtBlockExternal(
        address l1Address,
        uint256 blockNumber
    ) external confidential returns (bytes memory) {
        uint256 balance = getBalanceAtBlock(l1Address, blockNumber);
        SealedAuctionValidator sealedAuction = SealedAuctionValidator(
            msg.sender
        );
        return sealedAuction.refuteWinnerCallback(l1Address, balance);
    }

    function getNearestPreviousBlockExternal(
        uint256 timestamp
    ) external etherscanKeyStored returns (uint256) {
        return getNearestPreviousBlock(timestamp);
    }

    // =============================================================
    //                  FUNCTIONALITY: RPC Calls
    // =============================================================

    function getNonce(
        address account
    ) internal alchemyKeyStored returns (uint256 nonce) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_getTransactionCount", "params": ["',
            toHexString(abi.encodePacked(account)),
            '", "latest" ], "id": "',
            toString(chainID),
            '"}'
        );
        bytes memory response = makePostRPCCall(_body);
        nonce = JSONParserLib.parseUintFromHex(
            trimQuotes(JSONParserLib.value(getJSONField(response, "result")))
        );
    }

    function getGasPrice() internal returns (uint256 gasPrice) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_gasPrice", "params": [], "id": ',
            toString(chainID),
            "}"
        );
        bytes memory response = makePostRPCCall(_body);

        gasPrice = JSONParserLib.parseUintFromHex(
            trimQuotes(JSONParserLib.value(getJSONField(response, "result")))
        );
    }

    function getNearestPreviousBlock(
        uint256 timestamp
    ) public etherscanKeyStored returns (uint256) {
        string memory url = string.concat(
            BASE_SEPOLIA_ETHERSCAN_URL,
            "?module=block&action=getblocknobytime&timestamp=",
            toString(timestamp),
            "&closest=before&apikey=",
            string(Suave.confidentialRetrieve(etherscanEndpoint, RPC))
        );
        bytes memory response = Suave.doHTTPRequest(
            Suave.HttpRequest({
                url: url,
                method: "GET",
                headers: getHeaders(),
                body: "",
                withFlashbotsSignature: false,
                timeout: 7000
            })
        );
        return
            JSONParserLib.parseUint(
                trimQuotes(
                    JSONParserLib.value(getJSONField(response, "result"))
                )
            );
    }

    function getBalanceAtBlock(
        address l1Address,
        uint256 finalETHBlock
    ) internal confidential returns (uint256 balance) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_getProof", "params": ["',
            toHexString(abi.encodePacked(l1Address)),
            '",[],"',
            LibString.toMinimalHexString(finalETHBlock),
            '"], "id": "',
            toString(chainID),
            '"}'
        );
        bytes memory response = makePostRPCCall(_body);
        balance = JSONParserLib.parseUintFromHex(
            trimQuotes(
                JSONParserLib.value(
                    JSONParserLib.at(
                        getJSONField(response, "result"),
                        '"balance"'
                    )
                )
            )
        );
    }

    function getBalance(
        address l1Address
    ) internal confidential returns (uint256 balance) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_getProof", "params": ["',
            toHexString(abi.encodePacked(l1Address)),
            '",[],"',
            "latest",
            '"], "id": "',
            toString(chainID),
            '"}'
        );
        bytes memory response = makePostRPCCall(_body);
        balance = JSONParserLib.parseUintFromHex(
            trimQuotes(
                JSONParserLib.value(
                    JSONParserLib.at(
                        getJSONField(response, "result"),
                        '"balance"'
                    )
                )
            )
        );
    }

    // sign and issue new transactions in order to move funds and NFTs
    function makeTransaction(
        address toAddress,
        uint256 gas,
        uint256 gasPrice,
        uint256 value,
        bytes memory payload,
        Suave.DataId suaveDataID
    ) internal alchemyKeyStored returns (bytes memory) {
        bytes memory privateL1Key = Suave.confidentialRetrieve(
            suaveDataID,
            PRIVATE_KEYS
        );
        address fromAddress = Secp256k1.deriveAddress(string(privateL1Key));
        uint256 nonce = getNonce(fromAddress);

        Transactions.EIP155Request memory txnWithToAddress = Transactions
            .EIP155Request({
                to: toAddress,
                gas: gas,
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

        sendRawTxHttpRequest(rlpEncodedTxn);

        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // =============================================================
    //                  HTTPS UTILITIES
    // =============================================================
    function getHeaders() internal pure returns (string[] memory) {
        string[] memory headers = new string[](1);
        headers[0] = "Content-Type: application/json";
        return headers;
    }

    function makePostRPCCall(
        bytes memory _body
    ) internal alchemyKeyStored returns (bytes memory) {
        return
            Suave.doHTTPRequest(
                Suave.HttpRequest({
                    url: getRPCEndpointURL(),
                    method: "POST",
                    headers: getHeaders(),
                    body: _body,
                    withFlashbotsSignature: false,
                    timeout: 7000
                })
            );
    }

    function makeGetRPCCall(
        string memory path
    ) internal alchemyKeyStored returns (bytes memory) {
        return
            Suave.doHTTPRequest(
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

    function sendRawTxHttpRequest(
        bytes memory rlpEncodedTxn
    ) internal alchemyKeyStored returns (bytes memory response) {
        bytes memory _body = abi.encodePacked(
            '{"jsonrpc":"2.0", "method": "eth_sendRawTransaction", "params": ["',
            toHexString(rlpEncodedTxn),
            '"], "id": "',
            toString(chainID),
            '"}'
        );
        response = makePostRPCCall(_body);
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
}
