// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../math/IterableMapping.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LotteryTracker is Ownable, VRFConsumerBase {
    using SafeMath for uint256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private hourlyHoldersMap;

    mapping(address => bool) public excludedFromHourly;

    uint256 public lastHourlyDistributed;

    uint256 private minTokenBalForHourly = 1 * 10**6 * 10**18;
    address private constant BUSD = address(0x77c21c770Db1156e271a3516F89380BA53D594FA); //BUSD

    uint256 hourlyAmount;

    bytes32 internal keyHash;
    uint256 internal fee;

    uint256 public randomResult;
    uint256 private oldResult;

    event HourlyLotteryWinners(address winner, uint256 Amount);

    /**
     * Constructor inherits VRFConsumerBase
     *
     * Network: BSC Testnet
     * Chainlink VRF Coordinator address: 0xa555fC018435bef5A13C6c6870a9d4C11DEC329C
     * LINK token address               : 0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06
     * Key Hash: 0xcaf3c3727e033261d383b315559476f48034c13b18f8cafed4d871abe5049186
     */

    constructor()
        VRFConsumerBase(
            0xa555fC018435bef5A13C6c6870a9d4C11DEC329C, // VRF Coordinator
            0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06 // LINK Token
        )
    {
        keyHash = 0xcaf3c3727e033261d383b315559476f48034c13b18f8cafed4d871abe5049186;
        fee = 0.1 * 10**18; // 0.1 LINK (Varies by network)
        lastHourlyDistributed = block.timestamp;
        excludedFromHourly[address(0xdead)] = true;
    }

    function setLottery(uint256 amount) public onlyOwner {
        hourlyAmount = hourlyAmount.add(amount);
    }

    function getRandomNumber() public onlyOwner returns (bytes32 requestId) {
        require(
            LINK.balanceOf(address(this)) >= fee,
            "Not enough LINK - fill contract with faucet"
        );
        return requestRandomness(keyHash, fee);
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness)
        internal
        override
    {
        randomResult = randomness;
        requestId = 0;
    }

    function excludeFromHourly(address account) external onlyOwner {
        excludedFromHourly[account] = true;
        hourlyHoldersMap.remove(account);
    }

    function setMinValues(uint256 hourly) external onlyOwner {
        minTokenBalForHourly = hourly;
    }

    function pickHourlyWinners() public {
        require(randomResult != oldResult, "Update random number first");

        uint256 holderCount = hourlyHoldersMap.keys.length;
        address winner;

        winner = hourlyHoldersMap.getKeyAtIndex(randomResult.mod(holderCount));
        uint256 wonAmount = (hourlyAmount * IERC20(owner()).balanceOf(winner)) / IERC20(owner()).totalSupply();
        IERC20(BUSD).transfer(winner, wonAmount);

        lastHourlyDistributed = block.timestamp;
        oldResult = randomResult;
        hourlyAmount = 0;

        emit HourlyLotteryWinners(winner, wonAmount);
    }

    function setAccount(address payable account, uint256 newBalance)
        external
        onlyOwner
    {
        if (newBalance >= minTokenBalForHourly) {
            if (excludedFromHourly[account]) {
                return;
            }
            hourlyHoldersMap.set(account, newBalance);
        } else {
            hourlyHoldersMap.remove(account);
        }
    }
}
