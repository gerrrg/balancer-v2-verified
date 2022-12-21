// Factory to create pools of secondary issues for security token offerings
// (c) Kallol Borah, 2022
//"SPDX-License-Identifier: BUSL1.1"

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";

import "@balancer-labs/v2-pool-utils/contracts/factories/BasePoolFactory.sol";
import "@balancer-labs/v2-pool-utils/contracts/factories/FactoryWidePauseWindow.sol";

import "./SecondaryIssuePool.sol";
import "./interfaces/ISecondaryIssuePoolFactory.sol";

contract SecondaryIssuePoolFactory is BasePoolFactory, FactoryWidePauseWindow {
    constructor(IVault vault, IProtocolFeePercentagesProvider protocolFeeProvider) 
        BasePoolFactory(vault, protocolFeeProvider, type(SecondaryIssuePool).creationCode)
    {
        // solhint-disable-previous-line no-empty-blocks
    }

    function create(
        // GERG: I would lose the leading underscores here since they are not a storage variables
        string calldata _name,
        string calldata _symbol,
        address _security,
        address _currency,
        uint256 _maxAmountsIn,
        uint256 _tradeFeePercentage
    ) external returns (address) {
        
        (uint256 pauseWindowDuration, uint256 bufferPeriodDuration) = getPauseConfiguration();

        return
            _create(
                abi.encode(  
                    getVault(),
                    // GERG: I would lose the leading underscores here since they are not a storage variables
                    _name,
                    _symbol,
                    _security,
                    _currency,
                    _maxAmountsIn,
                    _tradeFeePercentage,
                    pauseWindowDuration,
                    bufferPeriodDuration,
                    msg.sender
                ));
    }

}