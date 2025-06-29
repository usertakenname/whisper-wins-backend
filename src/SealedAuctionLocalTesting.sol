// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";
import "suave-std/Context.sol";
import "suave-std/Transactions.sol";
import "suave-std/suavelib/Suave.sol";
import "suave-std/Gateway.sol";
import "suave-std/protocols/EthJsonRPC.sol";
import "suave-std/crypto/Secp256k1.sol";
import "solady/src/utils/JSONParserLib.sol";
import "solady/src/utils/LibString.sol";

interface Oracle {
    function getNFTOwnedBy(
        address _nftContract,
        uint256 _tokenId
    ) external returns (address);
    function endAuction(
        address[] memory l1Addresses,
        uint256 endTimestamp
    ) external returns (uint256, address);
    function transferETH(
        address returnAddress,
        Suave.DataId suaveDataID
    ) external;
    function transferNFT(
        address from,
        address to,
        address nftContract,
        uint256 tokenId,
        Suave.DataId suaveDataID
    ) external;
    function transferETHForNFT(
        address returnAddress,
        Suave.DataId suaveDataID
    ) external;
}

contract SealedAuction is Suapp {
    address public auctioneerSUAVE;
    address public auctionWinnerL1 = address(0);
    address public auctionWinnerSuave = address(0);
    address public oracle; // hard coded address for Oracle on Toliman Chain
    address public nftHoldingAddress;
    address public nftContract;

    uint256 public winningBid = 0;
    uint256 public tokenId;
    uint256 public auctionEndTime;
    uint256 public minimalBid;

    bool public auctionHasStarted = false;

    /**
     * @notice Creates the sealed auction contract to auction off a NFT.
     * @param nftContractAddress contract address of the to be auctioned off NFT.
     * @param nftTokenId the according Token ID of the NFT
     * @param _auctionEndTime a linux timestamp;  all bids after that timestamp are not considered
     * @param minimalBiddingAmount every bid less than that will not be considered
     */
    constructor(
        address nftContractAddress,
        uint256 nftTokenId,
        uint256 _auctionEndTime,
        uint256 minimalBiddingAmount,
        address _oracle
    ) {
        auctioneerSUAVE = msg.sender;
        nftContract = nftContractAddress;
        tokenId = nftTokenId;
        auctionEndTime = _auctionEndTime;
        minimalBid = minimalBiddingAmount;
        oracle = _oracle;
    }

    // ===========================================================
    // Section: MODIFIERS
    // ===========================================================

    // restrict sensitive functionality to the deployer of the smart contract
    modifier onlyAuctioneer() {
        require(
            msg.sender == auctioneerSUAVE,
            "You are not the auctioneer of this auction"
        );
        _;
    }

    // modifiers to restrict auction-state sensitive functionality
    modifier auctionStarted() {
        require(auctionHasStarted, "Auction not yet started");
        _;
    }

    modifier auctionNotStarted() {
        require(!auctionHasStarted, "Auction has already started");
        _;
    }

    // bidders can not back out in the last 15 minutes of the auction
    modifier inBackOutTime() {
        require(auctionHasStarted, "Auction not yet started");
        uint256 until = auctionEndTime - 15 * 60;
        require(
            block.timestamp <= until,
            string.concat(
                "Auction ending too soon! Current timestamp: ",
                toString(block.timestamp),
                " > back out until timestamp: ",
                toString(until)
            )
        );
        _;
    }

    modifier afterAuctionTime() {
        require(auctionHasStarted, "Auction not yet started");
        require(
            block.timestamp >= auctionEndTime,
            string.concat(
                "Auction time not over yet! Current timestamp: ",
                toString(block.timestamp),
                " < auction ending timestamp: ",
                toString(auctionEndTime)
            )
        );
        _;
    }

    // checks whether the @field auctionEndTime is not in the past (used for startAuction())
    modifier validAuctionEndTime() {
        require(
            block.timestamp < auctionEndTime,
            string.concat(
                "Auction ending time is over already! Current timestamp: ",
                toString(block.timestamp),
                " > auction endin timestamp: ",
                toString(auctionEndTime)
            )
        );
        _;
    }

    modifier onlyOracle() {
        require(
            msg.sender == oracle,
            "Only the oracle can perform this operation"
        );
        _;
    }

    modifier winnerRegistered() {
        require(auctionWinnerL1 != address(0), "No L1-winner registered");
        require(auctionWinnerSuave != address(0), "No SUAVE-winner registered");
        _;
    }

    modifier notWinnerSuave() {
        require(
            !checkIsWinner(msg.sender),
            "You cannot refund your bid as you are the winner of the auction"
        );
        _;
    }

    modifier isWinnerSuave() {
        require(
            checkIsWinner(msg.sender),
            "You are the winner of the auction and can therefore not do this action"
        );
        _;
    }

    function checkIsWinner(
        address checkSuaveAddress
    ) internal view winnerRegistered returns (bool) {
        return checkSuaveAddress == auctionWinnerSuave;
    }

    // simple callback to publish offchain events
    function onchainCallback() public emitOffchainLogs {}


    // ===========================================================
    // Section: SETUP AUCTION RELATED FUNCTIONALITY
    // ===========================================================

    event NFTHoldingAddressEvent(address nftHoldingAddress);

    /**
     * @notice Generates a new nftHoldingAddress where the NFT is supposed to be sent to.
     * @dev The contract is the only entity in control of this address.
     * @dev Only confidentially callable by the auctioneer. Idempotent operation.
     * @custom:emits NFTHoldingAddressEvent event containing the address.
     */
    function setUpAuction()
        public
        confidential
        onlyAuctioneer
        returns (bytes memory)
    {
        if (nftHoldingAddress == address(0)) {
            // generate fresh EOA to store the NFT in during the auction
            string memory privateKey = Suave.privateKeyGen(
                Suave.CryptoSignature.SECP256
            );
            bytes memory keyData = bytes(privateKey);

            address[] memory stores = new address[](1);
            stores[0] = address(this);
            address[] memory peekers = new address[](2);
            peekers[0] = address(this);
            peekers[1] = oracle; // oracle can also see private keys
            Suave.DataRecord memory record = Suave.newDataRecord(
                0,
                peekers,
                stores,
                PRIVATE_KEYS
            );
            Suave.confidentialStore(record.id, PRIVATE_KEYS, keyData);
            address _nftHoldingAddress = Secp256k1.deriveAddress(privateKey);
            emit NFTHoldingAddressEvent(_nftHoldingAddress);
            return
                abi.encodeWithSelector(
                    this.setUpAuctionOnchain.selector,
                    _nftHoldingAddress,
                    record.id
                );
        }
        emit NFTHoldingAddressEvent(nftHoldingAddress);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // TODO: delete
    // gets privateKey of NFT Holding address
    event TestEvent(string test);
    function getPrivKey() public returns (bytes memory) {
        bytes memory privateL1Key = Suave.confidentialRetrieve(
            privateKeysL1[address(this)],
            PRIVATE_KEYS
        );
        emit TestEvent(string(privateL1Key));
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    /**
     * @notice Registers the nftHoldingAddress onchain.
     * @dev only called by setUpAuction()
     * @param keyRecord contains the Suave Data ID to lookup the private key in the Confidential Storage.
     * @param _nftHoldingAddress the address where the NFT must be sent to.
     */
    function setUpAuctionOnchain(
        address _nftHoldingAddress,
        Suave.DataId keyRecord
    ) public {
        nftHoldingAddress = _nftHoldingAddress;
        privateKeysL1[address(this)] = keyRecord; // The lookup address for the NFT-holding-address private-key is the auction contracts address
    }

    // ===========================================================
    // Section: START AUCTION
    // ===========================================================

    event AuctionOpened(
        address contractAddr,
        address nftContractAddress,
        uint256 nftTokenId,
        uint256 endTimestamp,
        uint256 minimalBiddingAmount
    );

    function startAuction()
        public
        onlyAuctioneer
        auctionNotStarted
        confidential
        validAuctionEndTime
        returns (bytes memory)
    {
        Oracle oracleRPC = Oracle(oracle);
        address NFTowner = oracleRPC.getNFTOwnedBy(nftContract, tokenId);
        require(
            NFTowner == nftHoldingAddress,
            "The NFT was not transferred yet"
        );
        return abi.encodeWithSelector(this.startAuctionOnchain.selector);
    }

    /**
     * @notice Officially starts the auction onchain.
     * @dev only called by startAuction().
     * @custom:emits AuctionOpened event.
     */
    function startAuctionOnchain() public emitOffchainLogs {
        auctionHasStarted = true;
        emit AuctionOpened(
            address(this),
            nftContract,
            tokenId,
            auctionEndTime,
            minimalBid
        );
    }

    // ===========================================================
    // Section: BIDDING
    // ===========================================================

    // returns the suave address and an encrypted bidding address in bytes
    event EncBiddingAddress(address owner, bytes encryptedL1Address);

    string public PRIVATE_KEYS = "KEY"; // lookup in the confidential storage

    // mapping of public SUAVE addresses to private keys of their bidding address on L1
    mapping(address => Suave.DataId) privateKeysL1;
    mapping(address => bool) _addressHasBid; // Suave sender to already has bid bool

    // keep track of the bidders: bidderAmount and mapping from i-th bidder to its SUAVE-address
    uint256 public bidderAmount = 0;
    mapping(uint256 => address) bidderAddresses;

    // store all L1 bidding addresses once revealed
    address[] public revealedL1Addresses = new address[](0);

    modifier addressHasBid(address owner) {
        require(
            _addressHasBid[owner],
            string.concat(
                "No bidding address related to this address: ",
                toHexString(abi.encodePacked(owner))
            )
        );
        _;
    }

    modifier senderHasBid() {
        require(
            _addressHasBid[msg.sender],
            string.concat(
                "No bidding address related to msg.sender: ",
                toHexString(abi.encodePacked(msg.sender))
            )
        );
        _;
    }

    modifier addressWithoutBid(address owner) {
        require(
            _addressHasBid[owner] == false,
            "Address already owns a bidding address"
        );
        _;
    }

    /**
     * @notice Get your personalized L1 bidding address to place your funds there (only decryptable by the caller).
     * @dev If the caller has no bidding address so far, create a new bidding address and/else emit it in an encrypted fashion.
     * @dev Assumes the secret key is freshly generated and kept confidential by the sender.
     * @dev This method can be called even before the start & after the end of an auction.
     * @custom:confidential-input a randomly created 32 byte key to be used for encryption.
     * @custom:emits EncBiddingAddress(Suave sender address, L1 bidding address encrypted in bytes).
     */
    function getBiddingAddress() public confidential returns (bytes memory) {
        bytes memory secretKey = Context.confidentialInputs();
        require(secretKey.length == 32, "Please provide a valid AES-256 key");
        if (_addressHasBid[msg.sender] == false) {
            // create a new L1 bidding address
            string memory privateKey = Suave.privateKeyGen(
                Suave.CryptoSignature.SECP256
            );
            bytes memory keyData = bytes(privateKey);

            address[] memory stores = new address[](1);
            stores[0] = address(this);
            address[] memory peekers = new address[](2);
            peekers[0] = address(this);
            peekers[1] = oracle; // oracle must have read access to use private key to sign transactions after the auction
            Suave.DataRecord memory record = Suave.newDataRecord(
                0,
                peekers,
                stores,
                PRIVATE_KEYS
            );
            Suave.confidentialStore(record.id, PRIVATE_KEYS, keyData);

            address publicL1Address = Secp256k1.deriveAddress(privateKey);
            bytes memory encrypted = encryptAddress(
                secretKey,
                abi.encodePacked(publicL1Address)
            );
            emit EncBiddingAddress(msg.sender, encrypted);
            return
                abi.encodeWithSelector(
                    this.getBiddingAddressOnchain.selector,
                    msg.sender,
                    record.id
                );
        } else {
            // bidder already has a personalized L1 bidding address => return this address
            bytes memory privateL1Key = Suave.confidentialRetrieve(
                privateKeysL1[msg.sender],
                PRIVATE_KEYS
            );
            address publicL1Address = Secp256k1.deriveAddress(
                string(privateL1Key)
            );
            bytes memory encrypted = encryptAddress(
                secretKey,
                abi.encodePacked(publicL1Address)
            );
            emit EncBiddingAddress(msg.sender, encrypted);
            return abi.encodeWithSelector(this.onchainCallback.selector);
        }
    }

    /**
     * @notice Registers the new bidding address on the contract. Increases bidder amount by one.
     * @dev only called by getBiddingAddress.
     */
    function getBiddingAddressOnchain(
        address owner,
        Suave.DataId keyRecord
    ) public emitOffchainLogs {
        privateKeysL1[owner] = keyRecord;
        _addressHasBid[owner] = true;
        bidderAddresses[bidderAmount++] = owner;
    }

    /**
     * @notice Encrypts the given address using AES-256.
     * @dev Ideally replace encryption by asymmetric crypto based on sender address, so that we don't rely on keymaterial
     * @dev provided by the user.
     * @param secretKey a randomly created 32 bytes key
     * @param publicL1Address the address to encrypt
     */
    function encryptAddress(
        bytes memory secretKey,
        bytes memory publicL1Address
    ) internal returns (bytes memory) {
        return Suave.aesEncrypt(secretKey, abi.encodePacked(publicL1Address));
    }

    // ===========================================================
    // Section: END AUCTION
    // ===========================================================

    event RevealBiddingAddresses(address[] bidderL1);

    /**
     * @notice Ends the auction by setting the winner. All bids being placed afterwards are invalid.
     * @dev Pretty expensive, as it calls the oracle to fetch the balance of every bidding address one by one.
     * @dev Refer to README "2. Poor Scalability" of section "Limitations and Simplifications"
     * @custom:emits RevealBiddingAddresses a list of all L1 bidding addresses in plain text
     */
    function endAuction() public confidential returns (bytes memory) {
        if (bidderAmount > 0) {
            if (revealedL1Addresses.length == 0) {
                // bidders not yet revealed and therefore no winner determined yet
                Oracle oracleRpc = Oracle(oracle);
                address[] memory toRevealBiddersL1 = new address[](
                    bidderAmount
                );
                // collect and reveal all L1 bidding addresses
                for (uint256 i = 0; i < bidderAmount; i++) {
                    bytes memory privateL1Key = Suave.confidentialRetrieve(
                        privateKeysL1[bidderAddresses[i]],
                        PRIVATE_KEYS
                    );
                    address publicL1Address = Secp256k1.deriveAddress(
                        string(privateL1Key)
                    );
                    toRevealBiddersL1[i] = (publicL1Address);
                }
                emit RevealBiddingAddresses(toRevealBiddersL1);
                // call the oracle to check the balances of these L1 addresses and determine the winner
                (uint256 _winningBid, address _winner) = oracleRpc.endAuction(
                    toRevealBiddersL1,
                    auctionEndTime
                );
                // now determine winning suave address
                for (uint256 i = 0; i < bidderAmount; i++) {
                    address publicL1Address = toRevealBiddersL1[i];
                    if (publicL1Address == _winner) {
                        // fund the NFT-holding address from the winning bid address such that it can issue the NFT-transferal when requested by the winner
                        // Note: If the winning bid is too small, the transaction might fail and the winner needs to fund the NFTHoldingAddress on his/herown
                        //       in order to claim it.
                        oracleRpc.transferETHForNFT(
                            nftHoldingAddress,
                            privateKeysL1[bidderAddresses[i]]
                        );

                        return
                            abi.encodeWithSelector(
                                this.endAuctionOnchain.selector,
                                _winner,
                                bidderAddresses[i],
                                _winningBid,
                                toRevealBiddersL1
                            );
                    }
                }
                // should not happen (otherwise the winner stated by the oracle is not contained in the bidding array)
                return
                    abi.encodeWithSelector(
                        this.endAuctionOnchain.selector,
                        address(0),
                        address(0),
                        0,
                        toRevealBiddersL1
                    );
            } else {
                // bidders have already been revealed once => no need to compute again
                emit RevealBiddingAddresses(revealedL1Addresses);
                return abi.encodeWithSelector(this.onchainCallback.selector);
            }
        } else {
            // no one bid => set winner to auctioneer
            return
                abi.encodeWithSelector(
                    this.endAuctionOnchain.selector,
                    auctioneerSUAVE,
                    auctioneerSUAVE,
                    0,
                    new address[](0)
                );
        }
    }

    /**
     * @notice Registers the winner and all L1 bidding addresses in the contract.
     * @notice If no bids or the minimal bidding amount is not kept, set the winner to the auctioneer
     * @dev only called by endAuction()
     * @param _winnerL1 L1 bidding address of the winner.
     * @param _winnerSUAVE SUAVE address of the winner.
     * @param _winningBid balance of the winning bid at the blockheight when the auction ended = Bid.
     * @param _l1Addresses all L1 bidding addresses (to be registered onchain).
     */
    function endAuctionOnchain(
        address _winnerL1,
        address _winnerSUAVE,
        uint256 _winningBid,
        address[] memory _l1Addresses
    ) public emitOffchainLogs {
        // set the autioneer as winner if no valid bid available
        if (_winningBid < minimalBid) {
            auctionWinnerL1 = auctioneerSUAVE;
            auctionWinnerSuave = auctioneerSUAVE;
            winningBid = 0;
        } else {
            auctionWinnerL1 = _winnerL1;
            auctionWinnerSuave = _winnerSUAVE;
            winningBid = _winningBid;
        }
        revealedL1Addresses = _l1Addresses;
    }

    /**
     * @notice Central method for all to claim their valuables. Losers get their bid back;
     * @notice Winner gets the NFT; Auctioneer gets the winning bid.
     * @dev No need to keep the returnAddress private by using a confidential input as the bidding address
     * @dev is public at this point anyway and anyone can track it's actions.
     * @param returnAddress L1 address where the valuables are to be sent.
     */
    function claim(
        string calldata returnAddress
    ) external confidential winnerRegistered returns (bytes memory) {
        
        address returnAddressL1 = toAddress(returnAddress);
        // when no one bid => auctioneer gets the NFT
        if (msg.sender == auctioneerSUAVE) {
            // auctioneer has to be checked first. Do not change the order!
            if (auctionWinnerSuave == auctioneerSUAVE) {
                // there is no winner -> transfer NFT back to auctioneer
                transferNFT(returnAddressL1);
            } else {
                transferWinningBid(returnAddressL1);
            }
        } else if (checkIsWinner(msg.sender)) {
            transferNFT(returnAddressL1);
        } else {
            refundBid(returnAddressL1);
        }
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    /**
     * @notice Transfers the highest (winning) bid to the auctioneer.
     * @dev calls the oracle to transfer ETH.
     * @param returnAddressL1 L1 address where the winning bid is to be sent to.
     */
    function transferWinningBid(
        address returnAddressL1
    ) internal onlyAuctioneer {
        Oracle oracleRPC = Oracle(oracle);
        oracleRPC.transferETH(
            returnAddressL1,
            privateKeysL1[auctionWinnerSuave]
        );
    }

    /**
     * @notice Transfers the auctioned NFT to the auction winner.
     * @dev calls the oracle to transfer NFT.
     * @param returnAddressL1 L1 address where the NFT is to be sent to.
     */
    function transferNFT(address returnAddressL1) internal isWinnerSuave {
        Oracle oracleRPC = Oracle(oracle);
        oracleRPC.transferNFT(
            nftHoldingAddress,
            returnAddressL1,
            nftContract,
            tokenId,
            privateKeysL1[address(this)]
        );
    }

    /**
     * @notice Refunds the bid to a loser.
     * @dev calls the oracle to transfer ETH.
     * @param returnAddressL1 L1 address where the bid is to be sent back to.
     */
    function refundBid(address returnAddressL1) internal notWinnerSuave {
        Oracle oracleRPC = Oracle(oracle);
        oracleRPC.transferETH(returnAddressL1, privateKeysL1[msg.sender]);
    }

    // ===========================================================
    // Section: BACK OUT FROM AUCTION
    // ===========================================================

    /**
     * @notice Before the auction has started, the auctioneer has the option to claim the NFT back.
     * @dev calls the oracle to transfer the NFT.
     * @param returnAddressL1 L1 address where the NFT is to be sent to.
     */
    function refundNFT(
        address returnAddressL1
    )
        public
        confidential
        onlyAuctioneer
        auctionNotStarted
        returns (bytes memory)
    {
        Oracle oracleRPC = Oracle(oracle);
        oracleRPC.transferNFT(
            nftHoldingAddress,
            returnAddressL1,
            nftContract,
            tokenId,
            privateKeysL1[address(this)]
        );
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    /**
     * @notice Until 15 minutes before the auction ends, a bidder is allowed to back out and reclaim the bid.
     * @dev A 15-minute threshold has been implemented to prevent scams. This ensures that the winner cannot issue a backout transaction at the last moment.
     * @dev If such a transaction were allowed, it could be included after the auction ends, enabling the winner to claim the NFT and withdraw their funds.
     * @dev calls the oracle to transfer the NFT.
     * @param returnAddressL1 L1 address where the balance is to be sent to.
     */
    function backOutBid(
        address returnAddressL1
    ) external confidential senderHasBid inBackOutTime returns (bytes memory) {
        Oracle oracleRPC = Oracle(oracle);
        oracleRPC.transferETH(returnAddressL1, privateKeysL1[msg.sender]);
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }

    // ===========================================================
    // Section: UTILS
    // ===========================================================

    function toHexString(
        bytes memory data
    ) internal pure returns (string memory) {
        return LibString.toHexString(data);
    }

    function toString(uint256 value) internal pure returns (string memory str) {
        return LibString.toString(value);
    }

     function toAddress(string memory hexString) internal pure returns (address) {
        bytes memory b = bytes(hexString);
        require(b.length == 42, "Invalid address length"); // 2 chars for "0x" + 40 hex digits

        uint160 result = 0;
        uint160 digit;
        for (uint256 i = 2; i < 42; i++) {
            uint8 char = uint8(b[i]);

            if (char >= 48 && char <= 57) {         // '0'–'9' => 0–9
                digit = uint160(char - 48);
            } else if (char >= 65 && char <= 70) {  // 'A'–'F' => 10–15
                digit = uint160(char - 55);
            } else if (char >= 97 && char <= 102) { // 'a'–'f' => 10–15
                digit = uint160(char - 87);
            } else {
                revert("Invalid hex character");
            }

            result = (result << 4) | digit;
        }

        return address(result);
     }
}
