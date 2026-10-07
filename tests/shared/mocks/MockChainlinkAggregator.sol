// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Controllable Chainlink AggregatorV3 mock for oracle slippage unit tests.
/// Allows tests to set price, decimals, staleness, and force reverts.
contract MockChainlinkAggregator {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _updatedAt;
    uint256 private _startedAt;
    uint80 private _roundId;
    bool private _shouldRevert;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
        // Defaults equal so existing price-feed tests are unaffected. A sequencer uptime feed keeps
        // these apart: startedAt is pinned to the last status change, updatedAt moves on every write.
        _startedAt = block.timestamp;
        _roundId = 1;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    /// @dev Tuple position 3. On an L2 sequencer uptime feed this is when the sequencer last
    /// changed status, which is what a grace period must be measured from.
    function setStartedAt(uint256 startedAt_) external {
        _startedAt = startedAt_;
    }

    function setRoundId(uint80 roundId_) external {
        _roundId = roundId_;
    }

    function setShouldRevert(bool val) external {
        _shouldRevert = val;
    }

    function decimals() external view returns (uint8) {
        require(!_shouldRevert, "MockChainlinkAggregator: forced revert");
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!_shouldRevert, "MockChainlinkAggregator: forced revert");
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }
}
