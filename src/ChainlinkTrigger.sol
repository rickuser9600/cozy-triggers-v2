// SPDX-License-Identifier: Unlicensed
pragma solidity 0.8.15;

import "chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "solmate/utils/FixedPointMathLib.sol";

import "src/abstract/BaseTrigger.sol";
import "src/interfaces/IManager.sol";

/**
 * @notice A trigger contract that takes two addresses: a truth oracle and a tracking oracle.
 * This trigger ensures the two oracles always stay within the given price tolerance; the delta
 * in prices can be equal to but not greater than the price tolerance.
 */
contract ChainlinkTrigger is BaseTrigger {
  using FixedPointMathLib for uint256;

  uint256 internal constant ZOC = 1e4;

  /// @notice The canonical oracle, assumed to be correct.
  AggregatorV3Interface public immutable truthOracle;

  /// @notice The oracle we expect to diverge.
  AggregatorV3Interface public immutable trackingOracle;

  /// @notice The maximum percent delta between oracle prices that is allowed, expressed as a zoc.
  /// For example, a 0.2e4 priceTolerance would mean the trackingOracle price is
  /// allowed to deviate from the truthOracle price by up to +/- 20%, but no more.
  /// Note that if the truthOracle returns a price of 0, we treat the priceTolerance
  /// as having been exceeded, no matter what price the trackingOracle returns.
  uint256 public immutable priceTolerance;

  /// @notice The maximum amount of time we allow to elapse before an oracle's price is deemed stale.
  uint256 public immutable frequencyTolerance;

  /// @dev Thrown when the `oracle`s price is negative.
  error InvalidPrice();

  /// @dev Thrown when the `oracle`s price timestamp is greater than the block's timestamp.
  error InvalidTimestamp();

  /// @dev Thrown when the `oracle`s last update is more than `frequencyTolerance` seconds ago.
  error StaleOraclePrice();

  /// @param _manager Address of the Cozy protocol manager.
  /// @param _truthOracle The canonical oracle, assumed to be correct.
  /// @param _trackingOracle The oracle we expect to diverge.
  /// @param _priceTolerance The maximum percent delta between oracle prices that is allowed, as a wad.
  /// @param _frequencyTolerance The maximum amount of time we allow to elapse before an oracle's price is deemed stale.
  constructor(
    IManager _manager,
    AggregatorV3Interface _truthOracle,
    AggregatorV3Interface _trackingOracle,
    uint256 _priceTolerance,
    uint256 _frequencyTolerance
  ) BaseTrigger(_manager) {
    truthOracle = _truthOracle;
    trackingOracle = _trackingOracle;
    priceTolerance = _priceTolerance;
    frequencyTolerance = _frequencyTolerance;
    runProgrammaticCheck();
  }

  /// @notice Compares the oracle's price to the reference oracle and toggles the trigger if required.
  /// @dev This method executes the `programmaticCheck()` and makes the
  /// required state changes both in the trigger and the sets.
  function runProgrammaticCheck() public returns (CState) {
    // Rather than revert if not active, we simply return the state and exit.
    // Both behaviors are acceptable, but returning is friendlier to the caller
    // as they don't need to handle a revert and can simply parse the
    // transaction's logs to know if the call resulted in a state change.
    if (state != CState.ACTIVE) return state;
    if (programmaticCheck()) return _updateTriggerState(CState.TRIGGERED);
    return state;
  }

  /// @dev Executes logic to programmatically determine if the trigger should be toggled.
  function programmaticCheck() internal view returns (bool) {
    uint256 _truePrice = _oraclePrice(truthOracle);
    uint256 _trackingPrice = _oraclePrice(trackingOracle);

    uint256 _priceDelta = _truePrice > _trackingPrice ? _truePrice - _trackingPrice : _trackingPrice - _truePrice;

    // We round up when calculating the delta percentage to accommodate for precision loss to
    // ensure that the state becomes triggered when the delta is greater than the price tolerance.
    // When the delta is less than or exactly equal to the price tolerance, the resulting rounded
    // up value will not be greater than the price tolerance, as expected.
    return _truePrice > 0 ? _priceDelta.mulDivUp(ZOC, _truePrice) > priceTolerance : true;
  }

  /// @dev Returns the current price of the specified `_oracle`.
  function _oraclePrice(AggregatorV3Interface _oracle) internal view returns (uint256 _price) {
    (,int256 _priceInt,, uint256 _updatedAt,) = _oracle.latestRoundData();
    if (_updatedAt > block.timestamp) revert InvalidTimestamp();
    if (block.timestamp - _updatedAt > frequencyTolerance) revert StaleOraclePrice();
    if (_priceInt < 0) revert InvalidPrice();
    _price = uint256(_priceInt);
  }
}