// Factory interface to create pools of new issues for security token offerings
// (c) Kallol Borah, Verified Network, 2021

//"SPDX-License-Identifier: MIT"

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

interface IPrimaryIssuePoolFactory {

    struct FactoryPoolParams{
        string name;
        string symbol;
        address security;
        address currency;
        uint256 minimumPrice;
        uint256 basePrice;
        uint256 maxAmountsIn;
        uint256 swapFeePercentage;
        uint256 cutOffTime;
        string offeringDocs;
    }

    function create(
        FactoryPoolParams memory params
    ) external returns (address);

}