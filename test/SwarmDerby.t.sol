// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby, IERC20} from "../src/SwarmDerby.sol";
import {DerbyOdds} from "../src/DerbyOdds.sol";

contract MockArbSys {
    uint256 public arbBlockNumber;
    mapping(uint256 => bytes32) public hashes;
    function setBlock(uint256 n) external { arbBlockNumber = n; }
    function arbBlockHash(uint256 n) external view returns (bytes32) {
        require(n < arbBlockNumber && n + 256 >= arbBlockNumber, "range");
        return hashes[n] != bytes32(0) ? hashes[n] : keccak256(abi.encode("blk", n));
    }
}

contract MockIMD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    function block_(address a) external { blocked[a] = true; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { require(!blocked[to], "blocked"); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract DerbyHarness is SwarmDerby {
    constructor(address owner_, address imd_) SwarmDerby(owner_, IERC20(imd_), 0.15 ether, 0.5 ether) {}
    function recordDinger(uint8 league, uint256 day, address p, uint256 f) external { _recordDinger(league, day, p, f); }
    function recordToday(uint8 league, address p, uint256 f) external { _recordDinger(league, currentDay(), p, f); }
}

contract SwarmDerbyTest is Test {
    MockArbSys arb = MockArbSys(address(100));
    MockIMD imd;
    DerbyHarness derby;
    address player = address(0xBA77E2);
    uint256 sessionPk = 0x5E55;
    address session;
    bytes32 constant SALT = keccak256("player-salt");
    uint256 constant DAY0 = 20_370;
    uint256 constant T0 = DAY0 * 1 days + 1 hours;

    function setUp() public {
        vm.etch(address(100), address(new MockArbSys()).code);
        arb.setBlock(1_000);
        vm.chainId(4663);
        vm.warp(T0);
        imd = new MockIMD();
        session = vm.addr(sessionPk);
        derby = new DerbyHarness(address(this), address(imd));
        imd.mint(player, 100 ether);
        vm.prank(player);
        imd.approve(address(derby), type(uint256).max);
    }

    function _buy(address who, uint8 league, uint256 n) internal {
        imd.mint(who, n * 0.15 ether);
        vm.startPrank(who);
        imd.approve(address(derby), type(uint256).max);
        derby.buyTurns(league, n);
        vm.stopPrank();
    }

    function _swingIn(uint8 league, uint8 q, uint8 v, bytes32 salt) internal returns (uint256) {
        bytes32 c = derby.commitFor(salt, player);
        vm.prank(player);
        return derby.swing(league, q, v, c);
    }

    function _swing(uint8 q, uint8 v, bytes32 salt) internal returns (uint256) {
        return _swingIn(0, q, v, salt);
    }

    /// Find a target block hash that makes `swingId` land at least `minTier` with this salt/quality.
    function _rig(uint256 swingId, uint8 q, uint8 minTier, string memory tag) internal returns (uint16 feet) {
        bytes32 h;
        for (uint256 i; ; ++i) {
            h = keccak256(abi.encode(tag, i));
            (uint8 t, uint16 f) = DerbyOdds.roll(derby.swingSeed(SALT, h), swingId, q, 100);
            if (t >= minTier) { feet = f; break; }
        }
        vm.store(address(100), keccak256(abi.encode(uint256(arb.arbBlockNumber() + 5), uint256(1))), h);
    }

    function _consent(uint256 pk, address forPlayer) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, derby.sessionDigest(forPlayer, vm.addr(pk)));
        return abi.encodePacked(r, s, v);
    }

    function _bindSession(address who, uint256 pk) internal {
        bytes memory sig = _consent(pk, who);
        vm.prank(who);
        derby.setSession(vm.addr(pk), sig);
    }

    /// Move past the end of the current day and past every reveal window.
    function _closeDay() internal {
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        arb.setBlock(arb.arbBlockNumber() + 1_000);
    }

    function _day(uint256 id) internal view returns (uint32 d) {
        (, , , , , , , d) = derby.swings(id);
    }

    // ───────── turns + leagues ─────────

    function test_buyPackSplitsPerLeague() public {
        vm.prank(player);
        derby.buyPacks(0, 1); // arcade: 5 turns for 0.5 IMD
        vm.prank(player);
        derby.buyPacks(1, 2); // agent: 10 turns for 1 IMD
        assertEq(derby.turns(0, player), 5);
        assertEq(derby.turns(1, player), 10);
        assertEq(imd.balanceOf(derby.DEAD()), 0.6 ether);
        assertEq(derby.pot(0), 0.225 ether);
        assertEq(derby.pot(1), 0.45 ether);
        assertEq(derby.dayPot(0, DAY0), 0.225 ether);
        assertEq(derby.dayPot(1, DAY0), 0.45 ether);
        assertEq(derby.vault(0), 0.05 ether);
        assertEq(derby.vault(1), 0.1 ether);
        assertEq(derby.opsBalance(), 0.075 ether);
    }

    function test_singleTurnPrice() public {
        uint256 before = imd.balanceOf(player);
        vm.prank(player);
        derby.buyTurns(0, 1);
        assertEq(derby.turns(0, player), 1);
        assertEq(before - imd.balanceOf(player), 0.15 ether);
        assertEq(derby.pot(0), 0.0675 ether);
    }

    function test_badLeagueRejected() public {
        vm.prank(player);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.buyPacks(2, 1);
    }

    function test_leagueTurnsAreSeparate() public {
        vm.prank(player);
        derby.buyTurns(1, 1); // agent turn only
        bytes32 c = derby.commitFor(SALT, player);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.NoTurns.selector);
        derby.swing(0, 50, 50, c);
    }

    function test_ownerIsConstructorArg() public {
        SwarmDerby d = new SwarmDerby(address(0xA11), IERC20(address(imd)), 0.15 ether, 0.5 ether);
        assertEq(d.owner(), address(0xA11));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        d.setPrices(0.2 ether, 0.6 ether);
    }

    function test_constructorRejectsZeroAddressesAndFreeTurns() public {
        vm.expectRevert(SwarmDerby.ZeroAddress.selector);
        new SwarmDerby(address(0), IERC20(address(imd)), 0.15 ether, 0.5 ether);
        vm.expectRevert(SwarmDerby.ZeroAddress.selector);
        new SwarmDerby(address(this), IERC20(address(0)), 0.15 ether, 0.5 ether);
        vm.expectRevert(SwarmDerby.BadPrice.selector);
        new SwarmDerby(address(this), IERC20(address(imd)), 0, 0.5 ether);
        vm.expectRevert(SwarmDerby.BadPrice.selector);
        new SwarmDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.04 ether);
    }

    // ───────── admin ─────────

    /// Finding 8: zero prices would let the owner (or anyone) drain vaults with free slams.
    function test_priceFloor() public {
        vm.expectRevert(SwarmDerby.BadPrice.selector);
        derby.setPrices(0, 0);
        vm.expectRevert(SwarmDerby.BadPrice.selector);
        derby.setPrices(0.0099 ether, 0.5 ether);
        derby.setPrices(0.01 ether, 0.05 ether);
        assertEq(derby.singlePrice(), 0.01 ether);
        assertEq(derby.packPrice(), 0.05 ether);
    }

    function test_ownershipIsTwoStep() public {
        derby.transferOwnership(address(0xB0B));
        assertEq(derby.owner(), address(this)); // nothing changes until the new owner accepts
        assertEq(derby.pendingOwner(), address(0xB0B));
        vm.prank(address(0xBAD));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.acceptOwnership();
        vm.prank(address(0xB0B));
        derby.acceptOwnership();
        assertEq(derby.owner(), address(0xB0B));
        assertEq(derby.pendingOwner(), address(0));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.setPrices(0.2 ether, 0.6 ether);
    }

    function test_ownershipMoveCanBeCancelled() public {
        derby.transferOwnership(address(0xB0B));
        derby.transferOwnership(address(0)); // cancels; there is no way to renounce
        vm.prank(address(0xB0B));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.acceptOwnership();
        assertEq(derby.owner(), address(this));
    }

    function test_ownerOnlyReachesOps() public {
        _buy(player, 0, 100);
        vm.expectRevert(); // 0.75 ops; the pot and vault are out of reach
        derby.withdrawOps(address(this), 0.76 ether);
        derby.withdrawOps(address(0xF0), 0.75 ether);
        assertEq(imd.balanceOf(address(0xF0)), 0.75 ether);
        assertEq(derby.pot(0), 6.75 ether);
        assertEq(derby.vault(0), 1.5 ether);
    }

    // ───────── arcade daily cap ─────────

    function test_arcadeCapIsTwentyPerDay() public {
        vm.prank(player);
        derby.buyPacks(0, 5); // 25 turns
        for (uint256 i; i < 20; ++i) _swing(0, 50, bytes32(0)); // misses still count
        assertEq(derby.arcadeSwingsLeft(player), 0);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.DailyCapReached.selector);
        derby.swing(0, 0, 50, bytes32(0));
        assertEq(derby.turns(0, player), 5); // unused turns carry over
        vm.warp(block.timestamp + 1 days);
        assertEq(derby.arcadeSwingsLeft(player), 20);
        _swing(0, 50, bytes32(0));
    }

    function test_agentLeagueHasNoCap() public {
        vm.prank(player);
        derby.buyPacks(1, 5);
        for (uint256 i; i < 25; ++i) _swingIn(1, 0, 50, bytes32(0));
        assertEq(derby.turns(1, player), 0);
    }

    function test_capCountsSessionSwingsForThePlayer() public {
        _bindSession(player, sessionPk);
        vm.prank(player);
        derby.buyPacks(0, 5);
        for (uint256 i; i < 20; ++i) { vm.prank(session); derby.swing(0, 0, 50, bytes32(0)); }
        vm.prank(session);
        vm.expectRevert(SwarmDerby.DailyCapReached.selector);
        derby.swing(0, 0, 50, bytes32(0));
    }

    /// Finding 7: a swing committed before midnight and revealed after it counts for the
    /// day it was committed, the same day its cap slot was taken.
    function test_lateFinalizeScoresOnCommitDay() public {
        vm.warp(DAY0 * 1 days + 1 days - 1); // 23:59:59
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint16 want = _rig(0, 100, DerbyOdds.HOMER, "midnight");
        uint256 id = _swing(100, 100, SALT);
        assertEq(_day(id), DAY0);
        vm.warp(DAY0 * 1 days + 1 days + 1); // next day
        arb.setBlock(1_006);
        derby.finalize(id, SALT);
        (address[] memory ps, uint256[] memory sc) = derby.board(0, DAY0);
        assertEq(ps[0], player);
        assertEq(sc[0], want);
        (ps, ) = derby.board(0, DAY0 + 1);
        assertEq(ps.length, 0);
        assertEq(derby.arcadeSwingsLeft(player), 20); // the new day's cap is untouched
    }

    // ───────── swings ─────────

    function test_whiffCostsTurnNoRoll() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(0, 50, bytes32(0));
        assertEq(derby.turns(0, player), 0);
        (, , , , SwarmDerby.Status st, , , ) = derby.swings(id);
        assertEq(uint8(st), uint8(SwarmDerby.Status.Final));
    }

    function test_contactNeedsCommit() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.BadCommit.selector);
        derby.swing(0, 50, 50, bytes32(0));
    }

    function test_qualityAndVeloBounded() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        bytes32 c = derby.commitFor(SALT, player);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.BadQuality.selector);
        derby.swing(0, 101, 50, c);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.BadQuality.selector);
        derby.swing(0, 50, 101, c);
    }

    function test_fullSwingMatchesOdds() public {
        vm.prank(player);
        derby.buyTurns(0, 5);
        uint256 id = _swing(73, 80, SALT);
        arb.setBlock(1_000 + 6);
        (uint8 tier, uint16 feet) = derby.finalize(id, SALT);
        bytes32 seed = derby.swingSeed(SALT, keccak256(abi.encode("blk", uint256(1_005))));
        (uint8 eTier, uint16 eFeet) = DerbyOdds.roll(seed, id, 73, 80);
        assertEq(tier, eTier);
        assertEq(feet, eFeet);
    }

    function test_finalizeTooEarly() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(50, 50, SALT);
        arb.setBlock(1_005);
        vm.expectRevert(SwarmDerby.TooEarly.selector);
        derby.finalize(id, SALT);
    }

    function test_wrongSaltRejected() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(50, 50, SALT);
        arb.setBlock(1_010);
        vm.expectRevert(SwarmDerby.BadSalt.selector);
        derby.finalize(id, keccak256("guess"));
    }

    function test_commitBoundToPlayer() public {
        address thief = address(0xBAD);
        _buy(thief, 0, 1);
        bytes32 c = derby.commitFor(SALT, player);
        vm.prank(thief);
        uint256 id = derby.swing(0, 50, 50, c);
        arb.setBlock(1_010);
        vm.expectRevert(SwarmDerby.BadSalt.selector);
        derby.finalize(id, SALT);
    }

    /// A token address with no code (e.g. the Ethereum IMD on Robinhood) deploys, but no
    /// purchase is ever credited, so there are no free turns and no unbacked pots.
    function test_tokenWithoutCodeRefusesPurchases() public {
        SwarmDerby d = new SwarmDerby(address(this), IERC20(address(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7)), 0.15 ether, 0.5 ether);
        vm.startPrank(player);
        vm.expectRevert(SwarmDerby.NotAContract.selector);
        d.buyTurns(0, 1);
        vm.expectRevert(SwarmDerby.NotAContract.selector);
        d.buyPacks(1, 1);
        vm.stopPrank();
        assertEq(d.turns(0, player), 0);
        assertEq(d.pot(0) + d.vault(0) + d.opsBalance(), 0);
    }

    function test_zeroCountPurchaseReverts() public {
        vm.startPrank(player);
        vm.expectRevert(SwarmDerby.ZeroCount.selector);
        derby.buyTurns(0, 0);
        vm.expectRevert(SwarmDerby.ZeroCount.selector);
        derby.buyPacks(1, 0);
        vm.stopPrank();
        assertEq(derby.openDays(0).length, 0);
        assertEq(derby.openDays(1).length, 0);
    }

    function test_revealAtWindowEdgeStillCounts() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        _rig(0, 100, DerbyOdds.HOMER, "edge");
        uint256 id = _swing(100, 100, SALT);
        arb.setBlock(1_005 + derby.FINALIZE_WINDOW()); // the chain still serves the hash
        (uint8 tier, ) = derby.finalize(id, SALT);
        assertGe(tier, DerbyOdds.HOMER);
    }

    function test_lateRevealIsFoul() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(100, 100, SALT);
        arb.setBlock(1_005 + derby.FINALIZE_WINDOW() + 1);
        (uint8 tier, uint16 feet) = derby.finalize(id, SALT);
        assertEq(tier, DerbyOdds.FOUL);
        assertEq(feet, 0);
    }

    function test_expireUnrevealed() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(100, 100, SALT);
        arb.setBlock(1_005 + derby.FINALIZE_WINDOW());
        vm.expectRevert(SwarmDerby.NotExpired.selector);
        derby.expire(id);
        arb.setBlock(1_005 + derby.FINALIZE_WINDOW() + 1);
        derby.expire(id);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, SALT);
    }

    function test_slamPaysTenPercentOfItsLeagueVault() public {
        _buy(player, 0, 100); // 15 IMD into arcade -> vault 1.5
        _buy(player, 1, 100); // 15 IMD into agent  -> vault 1.5
        _rig(0, 1, DerbyOdds.SLAM, "slam");
        uint256 id = _swing(1, 100, SALT);
        arb.setBlock(1_006);
        uint256 before = imd.balanceOf(player);
        (uint8 tier, ) = derby.finalize(id, SALT);
        assertEq(tier, DerbyOdds.SLAM);
        assertEq(imd.balanceOf(player) - before, 0.15 ether);
        assertEq(derby.vault(0), 1.35 ether);
        assertEq(derby.vault(1), 1.5 ether); // agent vault untouched
    }

    /// A slam the token refuses to pay keeps its prize in the vault, and the homer counts.
    function test_unpayableSlamKeepsPrizeAndHomer() public {
        _buy(player, 0, 100);
        uint16 feet = _rig(0, 1, DerbyOdds.SLAM, "slam");
        uint256 id = _swing(1, 100, SALT);
        imd.block_(player);
        arb.setBlock(1_006);
        (uint8 tier, ) = derby.finalize(id, SALT);
        assertEq(tier, DerbyOdds.SLAM);
        assertEq(derby.vault(0), 1.5 ether);
        assertEq(derby.dayScore(0, DAY0, player), feet);
        assertEq(imd.balanceOf(address(derby)), derby.pot(0) + derby.vault(0) + derby.opsBalance());
    }

    function test_swingStoresVelo() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(80, 42, SALT);
        (, , , uint8 v, , , , ) = derby.swings(id);
        assertEq(v, 42);
    }

    // ───────── sessions ─────────

    function test_sessionSwingsForPlayer() public {
        vm.prank(player);
        derby.buyTurns(0, 2);
        _bindSession(player, sessionPk);
        bytes32 c = derby.commitFor(SALT, player);
        vm.prank(session);
        uint256 id = derby.swing(0, 60, 70, c);
        assertEq(derby.turns(0, player), 1);
        (address who, , , , , , , ) = derby.swings(id);
        assertEq(who, player);
        arb.setBlock(1_006);
        vm.prank(session);
        derby.finalize(id, SALT);
    }

    function test_sessionRevokeAndRotate() public {
        _bindSession(player, 0x5E55);
        _bindSession(player, 0x5E56);
        assertEq(derby.playerOf(vm.addr(0x5E55)), vm.addr(0x5E55));
        assertEq(derby.playerOf(vm.addr(0x5E56)), player);
        vm.prank(player);
        derby.setSession(address(0), "");
        assertEq(derby.playerOf(vm.addr(0x5E56)), vm.addr(0x5E56));
        assertEq(derby.sessionOf(player), address(0));
    }

    function test_sessionCannotBeClaimedTwice() public {
        _bindSession(player, sessionPk);
        bytes memory sig = _consent(sessionPk, address(0xBEE));
        vm.prank(address(0xBEE));
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(session, sig);
    }

    /// Finding 2: nobody can bind someone else's address as their session key.
    function test_sessionNeedsTheKeysConsent() public {
        address victim = vm.addr(0xF00D);
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(victim, "");
        bytes memory forPlayer = _consent(0xF00D, player); // victim agreed to `player`, not attacker
        vm.prank(attacker);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(victim, forPlayer);
        bytes memory byAttacker = _consent(0xBAD, attacker); // wrong signer
        vm.prank(attacker);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(victim, byAttacker);
        assertEq(derby.playerOf(victim), victim);
    }

    function test_sessionConsentIsSingleUse() public {
        bytes memory sig = _consent(sessionPk, player);
        vm.prank(player);
        derby.setSession(session, sig);
        vm.prank(session);
        derby.leaveSession();
        vm.prank(player);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(session, sig); // nonce moved on
        _bindSession(player, sessionPk); // a fresh signature works
        assertEq(derby.playerOf(session), player);
    }

    function test_leaveSessionFreesTheKey() public {
        _bindSession(player, sessionPk);
        vm.prank(session);
        derby.leaveSession();
        assertEq(derby.playerOf(session), session);
        assertEq(derby.sessionOf(player), address(0));
        vm.prank(session);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.leaveSession();
    }

    function test_sessionChainsRejected() public {
        _bindSession(player, sessionPk);
        bytes memory sig = _consent(0x5E56, session);
        vm.prank(session); // a key can't take a key
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(vm.addr(0x5E56), sig);
        address other = vm.addr(0xC0FFEE); // a player with a key can't become a key
        _bindSession(other, 0x5E57);
        sig = _consent(0xC0FFEE, address(0xA1));
        vm.prank(address(0xA1));
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(other, sig);
        vm.prank(player); // nor can a player use itself
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(player, "");
    }

    /// Finding 9: turns a session key buys belong to its player.
    function test_sessionBuysForThePlayer() public {
        _bindSession(player, sessionPk);
        _buy(session, 0, 3);
        assertEq(derby.turns(0, player), 3);
        assertEq(derby.turns(0, session), 0);
    }

    // ───────── live scoreboards ─────────

    function test_finalizeUpdatesArcadeBoard() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint16 want = _rig(0, 100, DerbyOdds.HOMER, "hr");
        uint256 id = _swing(100, 100, SALT);
        arb.setBlock(1_006);
        derby.finalize(id, SALT);
        (address[] memory ps, uint256[] memory sc) = derby.board(0, DAY0);
        assertEq(ps[0], player);
        assertEq(sc[0], want);
        (address[] memory agents, ) = derby.board(1, DAY0);
        assertEq(agents.length, 0);
    }

    function test_arcadeKeepsLongestAgentKeepsTotal() public {
        derby.recordToday(0, address(0x1), 420);
        derby.recordToday(0, address(0x1), 390); // shorter: arcade best stays 420
        derby.recordToday(0, address(0x1), 505); // new best
        derby.recordToday(1, address(0x1), 420);
        derby.recordToday(1, address(0x1), 390);
        assertEq(derby.dayScore(0, DAY0, address(0x1)), 505);
        assertEq(derby.dayScore(1, DAY0, address(0x1)), 810);
    }

    function _checkBoard(uint8 league, address[] memory pool) internal view {
        (address[] memory ps, uint256[] memory fs) = derby.board(league, DAY0);
        assertLe(ps.length, 10);
        for (uint256 i = 1; i < ps.length; ++i) assertGe(fs[i - 1], fs[i], "sorted");
        uint256 floor = ps.length == 10 ? fs[9] : 0;
        uint256 onBoard;
        for (uint256 j; j < pool.length; ++j) {
            uint256 f = derby.dayScore(league, DAY0, pool[j]);
            bool listed;
            for (uint256 i; i < ps.length; ++i) if (ps[i] == pool[j]) { listed = true; assertEq(fs[i], f); }
            if (listed) ++onBoard;
            else if (ps.length == 10) assertLe(f, floor, "missing a leader");
            else assertEq(f, 0, "scorer missing from short board");
        }
        assertEq(onBoard, ps.length);
    }

    function testFuzz_boardsAreTopTen(uint256 seed) public {
        address[] memory pool = new address[](16);
        for (uint256 j; j < 16; ++j) pool[j] = address(uint160(0x1000 + j));
        for (uint256 k; k < 60; ++k) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint8 league = uint8(seed % 2);
            derby.recordToday(league, pool[(seed >> 1) % 16], 375 + (seed >> 8) % 246);
        }
        _checkBoard(0, pool);
        _checkBoard(1, pool);
    }

    function test_boardResetsEachDay() public {
        derby.recordToday(0, address(0x1), 400);
        vm.warp(block.timestamp + 1 days);
        derby.recordToday(0, address(0x2), 380);
        (address[] memory today, ) = derby.board(0, DAY0 + 1);
        (address[] memory yesterday, ) = derby.board(0, DAY0);
        assertEq(today.length, 1);
        assertEq(today[0], address(0x2));
        assertEq(yesterday[0], address(0x1));
    }

    // ───────── daily settlement ─────────

    function _podium(uint8 league, uint256 day) internal {
        derby.recordDinger(league, day, address(0x1), 600);
        derby.recordDinger(league, day, address(0x2), 500);
        derby.recordDinger(league, day, address(0x3), 450);
        derby.recordDinger(league, day, address(0x4), 400);
    }

    function test_settlePaysTheDaysTopThree() public {
        _buy(player, 0, 100); // arcade pot 6.75
        _buy(player, 1, 100); // agent pot 6.75
        _podium(0, DAY0);
        _closeDay();
        address settler = address(0x5E77);
        vm.prank(settler);
        derby.settleNextDay(0);
        assertEq(imd.balanceOf(settler), 0.030375 ether);
        assertEq(imd.balanceOf(address(0x1)), 3.626775 ether);
        assertEq(imd.balanceOf(address(0x2)), 1.51115625 ether);
        assertEq(imd.balanceOf(address(0x3)), 0.90669375 ether);
        assertEq(imd.balanceOf(address(0x4)), 0);
        assertEq(derby.pot(0), 0.675 ether);
        assertEq(derby.rollover(0), 0.675 ether);
        assertEq(derby.dayPot(0, DAY0), 0);
        assertEq(derby.pot(1), 6.75 ether); // agent pot untouched
    }

    function test_settleAgentLeague() public {
        _buy(player, 1, 100);
        derby.recordDinger(1, DAY0, address(0x9), 900);
        _closeDay();
        derby.settleNextDay(1);
        assertEq(imd.balanceOf(address(0x9)), 3.626775 ether);
        // unfilled 2nd and 3rd places roll over with the 10%
        assertEq(derby.rollover(1), 6.75 ether - 0.030375 ether - 3.626775 ether);
        assertEq(derby.pot(1), derby.rollover(1));
    }

    /// Finding 1: each day pays exactly once, in order, and nobody chooses the window.
    function test_eachDaySettlesOnceInOrder() public {
        _buy(player, 0, 10);
        _podium(0, DAY0);
        _closeDay();
        _buy(player, 0, 10);
        derby.recordDinger(0, DAY0 + 1, address(0x7), 420);
        _closeDay();
        uint256[] memory open = derby.openDays(0);
        assertEq(open.length, 2);
        assertEq(open[0], DAY0);
        assertEq(open[1], DAY0 + 1);

        derby.settleNextDay(0);
        assertEq(derby.settledDays(0), 1);
        assertGt(imd.balanceOf(address(0x1)), 0);
        assertEq(imd.balanceOf(address(0x7)), 0);
        derby.settleNextDay(0);
        assertGt(imd.balanceOf(address(0x7)), 0);
        uint256 paidTo1 = imd.balanceOf(address(0x1));
        vm.expectRevert(SwarmDerby.NothingToSettle.selector);
        derby.settleNextDay(0);
        assertEq(imd.balanceOf(address(0x1)), paidTo1);
        assertEq(derby.openDays(0).length, 0);
    }

    function test_settleWaitsForTheDayToEnd() public {
        vm.expectRevert(SwarmDerby.NothingToSettle.selector);
        derby.settleNextDay(0);
        _buy(player, 0, 10);
        _podium(0, DAY0);
        vm.expectRevert(SwarmDerby.DayNotOver.selector);
        derby.settleNextDay(0);
        vm.warp((DAY0 + 1) * 1 days); // midnight
        derby.settleNextDay(0); // no swings that day: nothing left to reveal
    }

    function test_settleWaitsForTheLastReveal() public {
        vm.warp(DAY0 * 1 days + 1 days - 1);
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(100, 100, SALT); // target 1_005
        vm.warp((DAY0 + 1) * 1 days + 1);
        arb.setBlock(1_005 + derby.FINALIZE_WINDOW());
        vm.expectRevert(SwarmDerby.DayNotOver.selector);
        derby.settleNextDay(0);
        arb.setBlock(1_005 + derby.FINALIZE_WINDOW() + 1);
        derby.settleNextDay(0);
        (uint8 tier, ) = derby.finalize(id, SALT); // too late to score
        assertEq(tier, DerbyOdds.FOUL);
        (address[] memory ps, ) = derby.board(0, DAY0);
        assertEq(ps.length, 0);
    }

    /// Finding 6: a day pays from its own purchases plus rollover, not from what later
    /// days have bought; later buyers can't be paid out to yesterday's winners.
    function test_settlePaysOnlyThatDaysPot() public {
        _buy(player, 0, 10); // day 0 pot 0.675
        _podium(0, DAY0);
        _closeDay();
        _buy(player, 0, 100); // day 1 pot 6.75
        (bool exists, bool ready, uint256 day, uint256 amount, uint256 tip) = derby.nextSettlement(0);
        assertTrue(exists);
        assertTrue(ready);
        assertEq(day, DAY0);
        assertEq(amount, 0.675 ether);
        assertEq(tip, 0.675 ether * 9000 / 10_000 * 50 / 10_000);
        derby.settleNextDay(0);
        assertEq(imd.balanceOf(address(0x1)), (0.675 ether * 9000 / 10_000 - tip) * 6000 / 10_000);
        assertEq(derby.dayPot(0, DAY0 + 1), 6.75 ether);
        assertEq(derby.pot(0), 6.75 ether + derby.rollover(0));
    }

    /// Finding 10: a day with no homers pays no tip; its whole pot rolls over.
    function test_emptyDayRollsOverWithoutTip() public {
        _buy(player, 0, 10);
        _closeDay();
        (, , , , uint256 tip) = derby.nextSettlement(0);
        assertEq(tip, 0);
        address settler = address(0x5E77);
        vm.prank(settler);
        derby.settleNextDay(0);
        assertEq(imd.balanceOf(settler), 0);
        assertEq(derby.rollover(0), 0.675 ether);
        assertEq(derby.pot(0), 0.675 ether);
        _buy(player, 0, 10);
        _podium(0, DAY0 + 1);
        _closeDay();
        (, , , uint256 amount, ) = derby.nextSettlement(0);
        assertEq(amount, 1.35 ether);
    }

    /// A winner the token won't pay can't stop the queue; that prize rolls over.
    function test_unpayableWinnerRollsOver() public {
        _buy(player, 0, 100);
        _podium(0, DAY0);
        imd.block_(address(0x2));
        _closeDay();
        derby.settleNextDay(0);
        assertEq(imd.balanceOf(address(0x1)), 3.626775 ether);
        assertEq(imd.balanceOf(address(0x2)), 0);
        assertEq(imd.balanceOf(address(0x3)), 0.90669375 ether);
        assertEq(derby.rollover(0), 0.675 ether + 1.51115625 ether);
        assertEq(derby.pot(0), derby.rollover(0));
        assertEq(imd.balanceOf(address(derby)), derby.pot(0) + derby.vault(0) + derby.opsBalance());
    }

    function test_nextSettlementBeforeAnything() public view {
        (bool exists, , , , ) = derby.nextSettlement(0);
        assertFalse(exists);
    }

    /// Money in = money out + money held, across days and leagues.
    function testFuzz_settlementConserves(uint256 seed) public {
        uint256 bought;
        for (uint256 d; d < 4; ++d) {
            for (uint256 k; k < 6; ++k) {
                seed = uint256(keccak256(abi.encode(seed, d, k)));
                uint8 league = uint8(seed % 2);
                address who = address(uint160(0x2000 + (seed >> 8) % 5));
                if ((seed >> 16) % 3 != 0) { _buy(who, league, 1 + (seed >> 24) % 9); bought += (1 + (seed >> 24) % 9) * 0.15 ether; }
                if ((seed >> 32) % 2 == 0) derby.recordToday(league, who, 375 + (seed >> 40) % 246);
            }
            _closeDay();
            for (uint8 l; l < 2; ++l) {
                (bool exists, bool ready, , , ) = derby.nextSettlement(l);
                while (exists) {
                    assertTrue(ready);
                    derby.settleNextDay(l);
                    (exists, ready, , , ) = derby.nextSettlement(l);
                }
                assertEq(derby.pot(l), derby.rollover(l));
            }
        }
        uint256 held = derby.pot(0) + derby.pot(1) + derby.vault(0) + derby.vault(1) + derby.opsBalance();
        assertEq(imd.balanceOf(address(derby)), held);
        assertEq(imd.balanceOf(derby.DEAD()), bought * 4000 / 10_000);
    }

    // ───────── odds ─────────

    function _check(bytes32 seed, uint256 id, uint8 q, uint8 v, uint8 tier, uint16 feet) internal pure {
        (uint8 t, uint16 f) = DerbyOdds.roll(seed, id, q, v);
        assertEq(t, tier, "tier mismatch vs browser");
        assertEq(f, feet, "feet mismatch vs browser");
    }

    /// Vectors generated by the browser engine (web/derby-odds.js), including under-the-line swings.
    function test_parityWithBrowser() public pure {
        _check(0x05bc33b3e0e7e55038cf2c4caa487678a25afb53409a5de239a90eb309fc8f03, 3, 1, 0, 1, 165);
        _check(0x36f324144249b75cdc483471aa9ecac526a64f2bd487cf626bfb8773e2543d68, 7922, 13, 59, 3, 422);
        _check(0xd2a2d740c327cec03dcf37fe32fbd0f2445445165f057ae6b6d20d470508ed38, 15841, 37, 60, 4, 510);
        _check(0x757f7373a898e0fa101f198af216c3a01f7cd77dcf38836230c1242ac627a912, 23760, 50, 100, 1, 132);
        _check(0xb89ae1dfeb136b01548c69643295f25e65acdf6de4786a531e797b1249bd4f2a, 31679, 64, 0, 3, 385);
        _check(0xbe352778f4642df9a49b0d77578afe61816073d2706b6d5b852c2bd1d623dabd, 39598, 88, 59, 3, 409);
        _check(0x41a1ba45cda70201806d20df9cd147892c80b87e4e8d5d9b9af8e836bb01877a, 47517, 100, 60, 3, 378);
        _check(0x1454d160032502df53eb878e0193a879b1ebe51a2e2cc10e85f451fdb3731079, 55436, 1, 100, 2, 221);
        _check(0x3f0324898afa315cba0bc47dde0c849b2ff9d9bd7a34d367a4ae2876190dae85, 63355, 13, 0, 3, 416);
        _check(0x1bf4da1c377b17ee9083e184b0d8787a20a207d99938f8c189a1262ab04142ac, 71274, 37, 59, 3, 418);
        _check(0x6e6b382950af22af85dd4241b9c854b1c1b97d8d00085115285bb587e0cf508d, 79193, 50, 60, 4, 509);
        _check(0x22ff5b1b5e3299819c8df89cc17857f1e4fe2366079b02df756037cfd2e54a7d, 87112, 64, 100, 3, 435);
        _check(0xdfac14bd91a200e8c8647744544f91e2d92a1cb00a5c57f570adc321f59c7246, 95031, 88, 0, 2, 275);
        _check(0x5ce9c3d4d22fd6ccac11c17bcf6a8ce2d34fbe80354bc18d40e57bf8485a88e6, 102950, 100, 59, 1, 131);
        _check(0x8443aa35061e45f85b83a40b2d10b456bb5b0c5b33c7fb812e3c57225ddeb646, 110869, 1, 60, 3, 425);
        _check(0x05f6ed293ae233189808861d1433960ee588b1e02d197dc3872df9be49764766, 118788, 13, 100, 3, 437);
        _check(0xefc467d758e4f70b15ee1df1048f587a87ca843cb83b92ccabd3ba1031b3e141, 126707, 37, 0, 2, 251);
        _check(0xef42948e02557c99144792133522f6669512a45197c6ae1a7c717101d317eff3, 134626, 50, 59, 2, 198);
        _check(0x2caebb28a374ab9e4ffbead79a471c2789ff00b572ed959ccf4cfe46c127cd6a, 142545, 64, 60, 1, 138);
        _check(0x0db847d606d210f8aa49ef562bad5902ecb99b3937e15df1f265fa301a2025d3, 150464, 88, 100, 2, 292);
        _check(0x98e0d1ac53d14946d3d354d9024efef09b4d46ed80c241330f0d647ad2009937, 158383, 100, 0, 2, 265);
        _check(0x6ab289f4d8d89ad5570fdc4237280c454edfe7ac55a91b05fef8ce9966789540, 166302, 1, 59, 3, 435);
        _check(0xd13df32ff4e1fb83ad990b57926ba71b8a6aa6efffd1ecf8e2f4356dfbe581f3, 174221, 13, 60, 2, 191);
        _check(0xb81bdd56a078b58c680ca073ef3452850a873b71be0545100296d1d593f9b73c, 182140, 37, 100, 3, 432);
        _check(0x1a61e0687c24086166f743fb7a9bfb9abadf475ba564bf96be790ce087e29c79, 1040, 100, 100, 5, 582);
        _check(0x1a61e0687c24086166f743fb7a9bfb9abadf475ba564bf96be790ce087e29c79, 1040, 100, 59, 3, 413);
    }

    /// Under the power line, no seed can produce a bomb or slam.
    function test_underPowerLineNoBombOrSlam() public pure {
        uint256 capped;
        for (uint256 i; i < 3000; ++i) {
            bytes32 seed = keccak256(abi.encode("power", i));
            (uint8 hi, ) = DerbyOdds.roll(seed, i, 1, 100);
            (uint8 lo, uint16 feet) = DerbyOdds.roll(seed, i, 1, 59);
            assertLe(lo, DerbyOdds.HOMER);
            if (hi > DerbyOdds.HOMER) {
                assertEq(lo, DerbyOdds.HOMER);
                assertGe(feet, 375);
                assertLe(feet, 449);
                ++capped;
            } else {
                assertEq(lo, hi);
            }
        }
        assertGt(capped, 0);
    }

    /// Finding 3: quality is self-reported, so better contact must never be worse. Every
    /// "at least pop / homer / bomb / slam" chance is non-decreasing in quality; a client
    /// that always claims 100 plays exactly like a perfect batter.
    function test_oddsMonotoneInQuality() public pure {
        uint256[5] memory prev = DerbyOdds.thresholds(1);
        for (uint8 q = 2; q <= 100; ++q) {
            uint256[5] memory c = DerbyOdds.thresholds(q);
            for (uint256 k; k < 5; ++k) assertLe(c[k], prev[k], "a better swing lost odds");
            prev = c;
        }
        uint256[5] memory top = DerbyOdds.thresholds(100);
        assertEq(top[0], 1000); // foul 10%
        assertEq(top[1], 3500); // pop 25%
        assertEq(top[2], 8920); // homer 54.2%
        assertEq(top[3], 9920); // bomb 10%, slam 0.8%
        uint256[5] memory low = DerbyOdds.thresholds(1);
        assertEq(low[0], 2980);
        assertEq(10_000 - low[3], 21); // slam 0.21%
    }
}
