// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title DerbyOdds
/// @notice Swing outcome table for Swarm Derby. The browser runs the exact same math
///         (see `DerbyOdds` in the site's game.html and web/derby-odds.js), so a result
///         shown on screen is the result the contract pays.
/// @dev Quality (1-100) comes from exit velocity + contact timing, and velo from the mash
///      meter. Both are reported by the client, so a script can always claim 100: it plays
///      like a perfect batter. The table is built for that. A higher quality never lowers
///      the chance of any result at or above pop, homer, bomb or slam, so the best the
///      client can do is play perfectly, and a perfect swing is a fair, capped edge:
///      0.8% slams against 0.2% at the bottom. The arcade's daily swing cap holds for
///      people and scripts alike. A swing under POWER_LINE exit velo can't produce a bomb
///      or slam.
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
    ///         interpolated linearly between quality 0 and quality 100. Every threshold
    ///         falls as quality rises, so better contact is never worse.
    ///         Quality 100: foul 10%, pop 25%, homer 54.2%, bomb 10%, slam 0.8%.
    function thresholds(uint8 quality) internal pure returns (uint256[5] memory c) {
        uint256 q = quality > 100 ? 100 : quality;
        uint256 iq = 100 - q;
        c[0] = (3000 * iq + 1000 * q) / 100;
        c[1] = (5000 * iq + 3500 * q) / 100;
        c[2] = (9500 * iq + 8920 * q) / 100;
        c[3] = (9980 * iq + 9920 * q) / 100;
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
