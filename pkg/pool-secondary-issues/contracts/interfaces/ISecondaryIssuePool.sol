// Secondary issue pool interface 
//"SPDX-License-Identifier: MIT"

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

interface IPrimaryIssuePool {

    function getPoolId() external returns(bytes32);

    function initialize() external;

    function getSecurity() external view returns (address);

    function getCurrency() external view returns (address);

    function exit() external;

}
