// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/SealedAuction.sol";
import "solady/src/utils/LibString.sol";
import "suave-std/crypto/Secp256k1.sol";
import "suave-std/suavelib/Suave.sol";

// Minimal Oracle mock
contract OracleMock {
    function getNFTOwnedBy(address, uint256) external pure returns (address) {
        return address(0xD);
    }
    function endAuction(
        address[] memory,
        uint256
    ) external pure returns (uint256, address) {
        return (1000, address(0x9E3b6d786Dc411aA33B9bD81f15436C9eCbB4cb0));
    }
    function transferETH(address, bytes32) external {}
    function transferNFT(
        address,
        address,
        address,
        uint256,
        bytes32
    ) external {}
    function transferETHForNFT(address, bytes32) external {}
}

contract SealedAuctionTest is Test {
    SealedAuction auction;
    OracleMock oracle;
    address auctioneer = address(0xA);
    address bidder = address(0xB1);
    address nftContract = address(0xC);
    address nftHoldingAddress = address(0xD);
    uint256 tokenId = 1;
    uint256 auctionEndTime = block.timestamp + 1 days;
    uint256 minimalBid = 1 gwei;
    string privKey =
        "4c0883a69102937d6231471b5dbb6204fe512961708279ba1ab2f5d4df8a5bfc";
    // add: 0x9E3b6d786Dc411aA33B9bD81f15436C9eCbB4cb0

    function test_setupAuction() public {
        Suave.DataRecord memory _dataRecord = mockConfidentialFeatures();
        address _nftHoldingAddress = Secp256k1.deriveAddress(privKey);

        vm.recordLogs();
        bytes memory ret = auction.setUpAuction();
        assertEq(
            ret,
            abi.encodeWithSelector(
                auction.setUpAuctionOnchain.selector,
                _nftHoldingAddress,
                _dataRecord.id
            )
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 1);
        assertEq(
            logs[0].topics[0],
            keccak256("NFTHoldingAddressEvent(address)")
        );
        console.log("NFTHOLDINGADDRESS EVENT:");
        console.log(abi.decode(logs[0].data, (address)));
        console.log("Emitter:");
        console.log(logs[0].emitter);
    }
    function test_setupAuctionOnchain() public {
        bytes16 recordId = bytes16(uint128(1));
        auction.setUpAuctionOnchain(
            address(0xBBB),
            Suave.DataId.wrap(recordId)
        );
        console.log("new nft holding address:");
        console.log(auction.nftHoldingAddress());
    }

    function test_startAuction() public {
        console.log(
            "Before starting auction: auctionHasStarted: ",
            auction.auctionHasStarted()
        );
        console.log("auctionEndTime: ", auction.auctionEndTime());
        console.log("current Block: ", vm.getBlockTimestamp());

        vm.mockCall(Suave.IS_CONFIDENTIAL_ADDR, bytes(""), abi.encode(true));
        vm.store(
            address(auction),
            bytes32(abi.encode(4)),
            bytes32(abi.encode(nftHoldingAddress))
        );
        bytes memory ret = auction.startAuction();

        assertEq(
            ret,
            abi.encodeWithSelector(auction.startAuctionOnchain.selector)
        );
    }

    function test_startAuctionOnchain() public {
        vm.recordLogs();
        auction.startAuctionOnchain();
        assertTrue(auction.auctionHasStarted());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 1);
        assertEq(
            logs[0].topics[0],
            keccak256("AuctionOpened(address,address,uint256,uint256,uint256)")
        );
    }

    function test_getBiddingAddress() public {
        bytes memory secretKey = abi.encode("10100011111110011100011100101011");
        Suave.DataRecord memory _dataRecord = mockConfidentialFeatures();
        bytes memory encryptedAddress = abi.encode("0xEEE");
        vm.mockCall(Suave.CONTEXT_GET, bytes(""), secretKey);
        vm.mockCall(Suave.AES_ENCRYPT, bytes(""), encryptedAddress);

        vm.stopPrank();
        vm.prank(bidder);
        bytes32 mappingSlot = bytes32(uint256(14));
        bytes32 key = bytes32(uint256(uint160(bidder)));
        bytes32 slot = keccak256(abi.encode(key, mappingSlot));

        bytes32 value = vm.load(address(auction), slot);
        bool hasBid = uint256(value) == 1;

        console.log("BEFORE: Bidder ", bidder, " has bid: ", hasBid);

        vm.recordLogs();
        bytes memory ret = auction.getBiddingAddress();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 1);
        assertEq(
            logs[0].topics[0],
            keccak256("EncBiddingAddress(address,bytes)")
        );
        (address payable sender, bytes memory encryptedAdd) = abi.decode(
            logs[0].data,
            (address, bytes)
        );
        assertEq(sender, bidder);
        assertEq(encryptedAddress, abi.encode("0xEEE"));
        assertEq(
            ret,
            abi.encodeWithSelector(
                auction.getBiddingAddressOnchain.selector,
                bidder,
                _dataRecord.id
            )
        );
    }

    function test_getBiddingAddressOnchain() public {
        uint256 bidderAmount = auction.bidderAmount();
        Suave.DataRecord memory _dataRecord = createSuaveDataRecord();
        bytes32 privateKeysSlot = bytes32(uint256(12));
        bytes32 hasBidSlot = bytes32(uint256(13));
        bytes32 bidderAddressesSlot = bytes32(uint256(15));

        bytes32 privateKeysKey = keccak256(abi.encode(bidder, privateKeysSlot));
        bytes32 hasBidKey = keccak256(abi.encode(bidder, hasBidSlot));
        bytes32 bidderAddressKey = keccak256(
            abi.encode(uint256(0), bidderAddressesSlot)
        );

        auction.getBiddingAddressOnchain(bidder, _dataRecord.id);

        assertEq(auction.bidderAmount(), bidderAmount + 1);
        bytes32 storedKeyRecord = vm.load(address(auction), privateKeysKey);
        bool hasBid = uint256(vm.load(address(auction), hasBidKey)) == 1;
        address storedBidderAddress = address(
            uint160(uint256(vm.load(address(auction), bidderAddressKey)))
        );

        assertEq(
            Suave.DataId.unwrap(_dataRecord.id),
            bytes16(uint128(uint256(storedKeyRecord)))
        );
        assertTrue(hasBid);
        assertEq(storedBidderAddress, bidder);
    }

    function test_getFiveBiddingAddress() public {
        bytes memory secretKey = abi.encode("10100011111110011100011100101011");
        Suave.DataRecord memory _dataRecord = mockConfidentialFeatures();
        bytes memory encryptedAddress = abi.encode("0xEEE");
        vm.mockCall(Suave.CONTEXT_GET, bytes(""), secretKey);
        vm.mockCall(Suave.AES_ENCRYPT, bytes(""), encryptedAddress);

        vm.stopPrank();
        vm.prank(bidder);
        bytes32 mappingSlot = bytes32(uint256(14));
        bytes32 key = bytes32(uint256(uint160(bidder)));
        bytes32 slot = keccak256(abi.encode(key, mappingSlot));

        bytes32 value = vm.load(address(auction), slot);
        bool hasBid = uint256(value) == 1;

        console.log("BEFORE: Bidder ", bidder, " has bid: ", hasBid);

        vm.recordLogs();
        bytes memory ret = auction.getBiddingAddress();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 1);
        assertEq(
            logs[0].topics[0],
            keccak256("EncBiddingAddress(address,bytes)")
        );
        (address payable sender, bytes memory encryptedAdd) = abi.decode(
            logs[0].data,
            (address, bytes)
        );
        assertEq(sender, bidder);
        assertEq(encryptedAddress, abi.encode("0xEEE"));
        assertEq(
            ret,
            abi.encodeWithSelector(
                auction.getBiddingAddressOnchain.selector,
                bidder,
                _dataRecord.id
            )
        );
        for (uint256 index = 0; index < 4; index++) {
            address bidder2 = address(0xB2);
            vm.prank(bidder2);
            auction.getBiddingAddress();
        }
    }

    function test_endAuction() public {
        Suave.DataRecord memory _dataRecord = mockConfidentialFeatures();
        vm.store(address(auction), bytes32(uint256(14)), bytes32(uint256(1)));
        vm.store(
            address(auction),
            bytes32(uint256(10)),
            bytes32(abi.encode(true))
        );
        vm.warp(86401);
        vm.mockCall(
            Suave.CONFIDENTIAL_RETRIEVE,
            bytes(""),
            abi.encodePacked(privKey)
        );
        vm.recordLogs();
        bytes memory ret = auction.endAuction();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 1);
        assertEq(
            logs[0].topics[0],
            keccak256("RevealBiddingAddresses(address[])")
        );
        address[] memory deb = abi.decode(logs[0].data, (address[]));
        console.log("privKEy: ", deb[0]);
    }

    function test_endAuctionOnchain() public {
        console.log("Minimal bid: ",auction.minimalBid());
        address[] memory addresses = new address[](1);
        addresses[0] = address(0x90);
        auction.endAuctionOnchain(address(0x99), address(0x98), 1 ether, addresses);

        address winnerL1 = auction.auctionWinnerL1();
        address winnerSuave = auction.auctionWinnerSuave();
        uint256 winningBid = auction.winningBid();
        address revealedAddresses = auction.revealedL1Addresses(0);
        assertEq(winnerL1, address(0x99));
        assertEq(winnerSuave, address(0x98));
        assertEq(winningBid, 1 ether);
        assertEq(revealedAddresses, address(0x90));
    }

    function setUp() public {
        oracle = new OracleMock();
        vm.startPrank(auctioneer);
        auction = new SealedAuction(
            nftContract,
            tokenId,
            auctionEndTime,
            minimalBid,
            address(oracle)
        );

        vm.store(
            address(auction),
            bytes32(uint256(3)),
            bytes32(uint256(uint160(address(oracle))))
        );
        logFields();
    }

    function logFields() view private {
        console.log(
            string.concat(
                "Auctioner: ",
                toHexString(
                    abi.encode(vm.load(address(auction), bytes32(uint256(0))))
                )
            )
        );
        console.log(
            string.concat(
                "auctionWinnerL1: ",
                toHexString(
                    abi.encode(vm.load(address(auction), bytes32(uint256(1))))
                )
            )
        );
        console.log(
            string.concat(
                "auctionWinnerSuave: ",
                toHexString(
                    abi.encode(vm.load(address(auction), bytes32(uint256(2))))
                )
            )
        );
        console.log(
            string.concat(
                "oracle: ",
                toHexString(
                    abi.encode(vm.load(address(auction), bytes32(uint256(3))))
                )
            )
        );
        console.log(
            string.concat(
                "NFTholdingAdd: ",
                toHexString(
                    abi.encode(vm.load(address(auction), bytes32(uint256(4))))
                )
            )
        );
        console.log(
            string.concat(
                "NFTContract: ",
                toHexString(
                    abi.encode(vm.load(address(auction), bytes32(uint256(5))))
                )
            )
        );
    }

    function mockConfidentialFeatures()
        private
        returns (Suave.DataRecord memory)
    {
        vm.mockCall(Suave.IS_CONFIDENTIAL_ADDR, bytes(""), abi.encode(true));
        vm.mockCall(Suave.PRIVATE_KEY_GEN, bytes(""), abi.encode(privKey));
        Suave.DataRecord memory _dataRecord = createSuaveDataRecord();
        vm.mockCall(Suave.NEW_DATA_RECORD, bytes(""), abi.encode(_dataRecord));
        vm.mockCall(Suave.CONFIDENTIAL_STORE, bytes(""), bytes(""));
        return _dataRecord;
    }

    function createSuaveDataRecord() private pure returns (Suave.DataRecord memory) {
        bytes16 recordId = bytes16(uint128(1));
        return
            Suave.DataRecord({
                id: Suave.DataId.wrap(recordId),
                salt: Suave.DataId.wrap(recordId),
                decryptionCondition: 0,
                allowedPeekers: new address[](0),
                allowedStores: new address[](0),
                version: ""
            });
    }

    /*
    function testSetUpAuction_FirstTime() public {
        // Should emit event and return setUpAuctionOnchain selector
        vm.prank(auctioneer);
        vm.expectEmit(true, false, false, false);
        emit SealedAuction.NFTHoldingAddressEvent(address(0xBEEF));
        bytes memory ret = auction.setUpAuction();
        // Check selector
        bytes4 selector;
        assembly { selector := mload(add(ret, 32)) }
        assertEq(selector, auction.setUpAuctionOnchain.selector);
        // Should set up a new holding address
        assertEq(auction.nftHoldingAddress(), address(0));
    }

    function testSetUpAuction_AlreadySet() public {
        // Set nftHoldingAddress to nonzero
        vm.prank(auctioneer);
        auction.setUpAuctionOnchain(address(0xBEEF), Suave.DataId(1));
        // Should emit event and return onchainCallback selector
        vm.prank(auctioneer);
        vm.expectEmit(true, false, false, false);
        emit SealedAuction.NFTHoldingAddressEvent(address(0xBEEF));
        bytes memory ret = auction.setUpAuction();
        bytes4 selector;
        assembly { selector := mload(add(ret, 32)) }
        assertEq(selector, auction.onchainCallback.selector);
        assertEq(auction.nftHoldingAddress(), address(0xBEEF));
    }

    function testSetUpAuction_NotAuctioneerReverts() public {
        vm.prank(notAuctioneer);
        vm.expectRevert("You are not the auctioneer of this auction");
        auction.setUpAuction();
    }

    function testSetUpAuctionOnchainSetsState() public {
        address holding = address(0xBEEF);
        Suave.DataId dataId = Suave.DataId(42);
        auction.setUpAuctionOnchain(holding, dataId);
        assertEq(auction.nftHoldingAddress(), holding);
        // Cannot check privateKeysL1 mapping directly, but no revert means success
    }*/

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
}
