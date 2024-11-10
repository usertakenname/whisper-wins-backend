// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "suave-std/Suapp.sol";

contract AuctionContract {
    address public owner;
    //TODO: Bids, Type of auction (create superclass), deadline etc.

    function onchainCallback() public {}

    event TestEvent(string);

    function test() external {
        emit TestEvent("Test working");
    }
}
