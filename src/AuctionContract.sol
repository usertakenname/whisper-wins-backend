// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";

contract AuctionContract is Suapp {
    address public owner;
    //TODO: Bids, Type of auction (create superclass), deadline etc.

    function onchainCallback() public emitOffchainLogs {}

    event TestEvent(string mes);

    function test() external returns (bytes memory) {
        emit TestEvent("Test working");
        return abi.encodeWithSelector(this.onchainCallback.selector);
    }
}
