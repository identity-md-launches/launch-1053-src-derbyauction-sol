// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title DerbyOdds
/// @notice Swing outcome table for Swarm Derby. The browser runs the exact same math
///         (see `DerbyOdds` in swarm_derby.html), so a result shown on screen is the
///         result the contract pays.
/// @dev Quality (1-100) comes from exit velocity + contact timing. It only changes
///      variance: expected home-run feet per swing is ~262.6 at every quality, so a
///      client that always claims quality 100 gains nothing in expectation. Clean
///      swings bust less; sloppy swings bust more but hit bombs and slams more often.
///      Separately, a swing under POWER_LINE exit velo can't produce a bomb or slam.
library DerbyOdds {
    uint8 internal constant WHIFF = 0;
    uint8 internal constant FOUL = 1;
    uint8 internal constant POP = 2;
    uint8 internal constant HOMER = 3;
    uint8 internal constant BOMB = 4;
    uint8 internal constant SLAM = 5;

    /// @notice Exit-velo score (0-100) a swing needs before a bomb or slam is possible.
    ///         Below it, those rolls land as regular homers.
    uint8 internal constant POWER_LINE = 60;

    /// @notice Cumulative odds (basis points) for [foul, pop, homer, bomb, slam],
    ///         interpolated linearly between quality 0 and quality 100.
    function thresholds(uint8 quality) internal pure returns (uint256[5] memory c) {
        uint256 q = quality > 100 ? 100 : quality;
        uint256 iq = 100 - q;
        c[0] = (3000 * iq + 1200 * q) / 100;
        c[1] = (4500 * iq + 3800 * q) / 100;
        c[2] = (6002 * iq + 9200 * q) / 100;
        c[3] = (9880 * iq + 9980 * q) / 100;
        c[4] = 10000;
    }

    /// @param seed     per-swing randomness
    /// @param swingId  unique swing id (domain-separates swings sharing a seed)
    /// @param quality  0 = whiff (no roll), 1-100 = contact quality
    /// @param velo     exit-velo score 0-100 from the mash meter
    /// @return tier    WHIFF..SLAM
    /// @return feet    landing distance; only HOMER and above count for the leaderboard
    function roll(bytes32 seed, uint256 swingId, uint8 quality, uint8 velo) internal pure returns (uint8 tier, uint16 feet) {
        if (quality == 0) return (WHIFF, 0);
        uint256 r = uint256(keccak256(abi.encode(seed, swingId, uint8(0)))) % 10000;
        uint256[5] memory c = thresholds(quality);
        if (r < c[0]) tier = FOUL;
        else if (r < c[1]) tier = POP;
        else if (r < c[2]) tier = HOMER;
        else if (r < c[3]) tier = BOMB;
        else tier = SLAM;
        if (tier > HOMER && velo < POWER_LINE) tier = HOMER;

        uint256 lo;
        uint256 span;
        if (tier == FOUL) { lo = 90; span = 81; }
        else if (tier == POP) { lo = 180; span = 121; }
        else if (tier == HOMER) { lo = 375; span = 75; }
        else if (tier == BOMB) { lo = 450; span = 100; }
        else { lo = 550; span = 71; }
        uint256 d = uint256(keccak256(abi.encode(seed, swingId, uint8(1))));
        feet = uint16(lo + (d % span));
    }
}
