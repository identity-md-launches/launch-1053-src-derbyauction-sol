// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
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
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract DerbyHarness is SwarmDerby {
    constructor(address imd_, address signer_) SwarmDerby(msg.sender, IERC20(imd_), 1, 1, signer_, bytes32(0), bytes32(0)) {}
    function recordDinger(uint8 league, address p, uint256 f) external { _recordDinger(league, p, f); }
}

contract SwarmDerbyTest is Test {
    MockArbSys arb = MockArbSys(address(100));
    MockIMD imd;
    SwarmDerby derby;
    address player = address(0xBA77E2);
    uint256 oraclePk = 0xA11CE;
    address oracleSigner;
    bytes32 constant Q_ARCADE = keccak256("derby-arcade-longest");
    bytes32 constant Q_AGENT = keccak256("derby-agent-total");
    bytes32 constant SALT = keccak256("player-salt");

    function setUp() public {
        vm.etch(address(100), address(new MockArbSys()).code);
        arb.setBlock(1_000);
        vm.chainId(4663);
        imd = new MockIMD();
        oracleSigner = vm.addr(oraclePk);
        derby = new SwarmDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.5 ether, oracleSigner, Q_ARCADE, Q_AGENT);
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
        SwarmDerby d = new SwarmDerby(address(0xA11), IERC20(address(imd)), 0.15 ether, 0.5 ether, oracleSigner, Q_ARCADE, Q_AGENT);
        assertEq(d.owner(), address(0xA11));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        d.setPrices(1, 1);
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
        address session = address(0x5E55);
        vm.prank(player);
        derby.setSession(session);
        vm.prank(player);
        derby.buyPacks(0, 5);
        for (uint256 i; i < 20; ++i) { vm.prank(session); derby.swing(0, 0, 50, bytes32(0)); }
        vm.prank(session);
        vm.expectRevert(SwarmDerby.DailyCapReached.selector);
        derby.swing(0, 0, 50, bytes32(0));
    }

    // ───────── swings ─────────

    function test_whiffCostsTurnNoRoll() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(0, 50, bytes32(0));
        assertEq(derby.turns(0, player), 0);
        (, , , , SwarmDerby.Status st, , ) = derby.swings(id);
        assertEq(uint8(st), uint8(SwarmDerby.Status.Final));
    }

    function test_contactNeedsCommit() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.BadCommit.selector);
        derby.swing(0, 50, 50, bytes32(0));
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

    function test_lateRevealIsFoul() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(100, 100, SALT);
        arb.setBlock(1_005 + 241);
        (uint8 tier, uint16 feet) = derby.finalize(id, SALT);
        assertEq(tier, DerbyOdds.FOUL);
        assertEq(feet, 0);
    }

    function test_expireUnrevealed() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(100, 100, SALT);
        arb.setBlock(1_005 + 240);
        vm.expectRevert(SwarmDerby.NotExpired.selector);
        derby.expire(id);
        arb.setBlock(1_005 + 241);
        derby.expire(id);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, SALT);
    }

    function test_sessionSwingsForPlayer() public {
        address session = address(0x5E55);
        vm.prank(player);
        derby.buyTurns(0, 2);
        vm.prank(player);
        derby.setSession(session);
        bytes32 c = derby.commitFor(SALT, player);
        vm.prank(session);
        uint256 id = derby.swing(0, 60, 70, c);
        assertEq(derby.turns(0, player), 1);
        (address who, , , , , , ) = derby.swings(id);
        assertEq(who, player);
        arb.setBlock(1_006);
        vm.prank(session);
        derby.finalize(id, SALT);
    }

    function test_sessionRevokeAndRotate() public {
        vm.prank(player);
        derby.setSession(address(0x5E55));
        vm.prank(player);
        derby.setSession(address(0x5E56));
        assertEq(derby.playerOf(address(0x5E55)), address(0x5E55));
        assertEq(derby.playerOf(address(0x5E56)), player);
        vm.prank(player);
        derby.setSession(address(0));
        assertEq(derby.playerOf(address(0x5E56)), address(0x5E56));
    }

    function test_sessionCannotBeClaimedTwice() public {
        vm.prank(player);
        derby.setSession(address(0x5E55));
        vm.prank(address(0xBEE));
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(address(0x5E55));
    }

    function test_slamPaysHalfOfItsLeagueVault() public {
        _buy(player, 0, 100); // 15 IMD into arcade -> vault 1.5
        _buy(player, 1, 100); // 15 IMD into agent  -> vault 1.5
        _rig(0, 1, DerbyOdds.SLAM, "slam");
        uint256 id = _swing(1, 100, SALT);
        arb.setBlock(1_006);
        uint256 before = imd.balanceOf(player);
        (uint8 tier, ) = derby.finalize(id, SALT);
        assertEq(tier, DerbyOdds.SLAM);
        assertEq(imd.balanceOf(player) - before, 0.75 ether);
        assertEq(derby.vault(0), 0.75 ether);
        assertEq(derby.vault(1), 1.5 ether); // agent vault untouched
    }

    // ───────── live scoreboards ─────────

    function test_finalizeUpdatesArcadeBoard() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint16 want = _rig(0, 100, DerbyOdds.HOMER, "hr");
        uint256 id = _swing(100, 100, SALT);
        arb.setBlock(1_006);
        derby.finalize(id, SALT);
        (address[] memory ps, uint256[] memory sc) = derby.board(0, derby.currentDay());
        assertEq(ps[0], player);
        assertEq(sc[0], want);
        (address[] memory agents, ) = derby.board(1, derby.currentDay());
        assertEq(agents.length, 0);
    }

    function test_arcadeKeepsLongestAgentKeepsTotal() public {
        DerbyHarness h = new DerbyHarness(address(imd), oracleSigner);
        uint256 day = h.currentDay();
        h.recordDinger(0, address(0x1), 420);
        h.recordDinger(0, address(0x1), 390);  // shorter: arcade best stays 420
        h.recordDinger(0, address(0x1), 505);  // new best
        h.recordDinger(1, address(0x1), 420);
        h.recordDinger(1, address(0x1), 390);
        assertEq(h.dayScore(0, day, address(0x1)), 505);
        assertEq(h.dayScore(1, day, address(0x1)), 810);
    }

    function test_arcadeGainsSumToLongest() public {
        // the oracle ranks by summed ArcadeGain; that sum must equal the player's best
        DerbyHarness h = new DerbyHarness(address(imd), oracleSigner);
        vm.recordLogs();
        uint16[6] memory hits = [uint16(401), 388, 470, 455, 512, 377];
        for (uint256 i; i < hits.length; ++i) h.recordDinger(0, address(0x1), hits[i]);
        bytes32 sig = keccak256("ArcadeGain(address,uint256)");
        uint256 sum;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == sig) sum += abi.decode(logs[i].data, (uint256));
        assertEq(sum, 512);
        assertEq(h.dayScore(0, h.currentDay(), address(0x1)), 512);
    }

    function _checkBoard(DerbyHarness h, uint8 league, address[] memory pool) internal view {
        uint256 day = h.currentDay();
        (address[] memory ps, uint256[] memory fs) = h.board(league, day);
        assertLe(ps.length, 10);
        for (uint256 i = 1; i < ps.length; ++i) assertGe(fs[i - 1], fs[i], "sorted");
        uint256 floor = ps.length == 10 ? fs[9] : 0;
        uint256 onBoard;
        for (uint256 j; j < pool.length; ++j) {
            uint256 f = h.dayScore(league, day, pool[j]);
            bool listed;
            for (uint256 i; i < ps.length; ++i) if (ps[i] == pool[j]) { listed = true; assertEq(fs[i], f); }
            if (listed) ++onBoard;
            else if (ps.length == 10) assertLe(f, floor, "missing a leader");
            else assertEq(f, 0, "scorer missing from short board");
        }
        assertEq(onBoard, ps.length);
    }

    function testFuzz_boardsAreTopTen(uint256 seed) public {
        DerbyHarness h = new DerbyHarness(address(imd), oracleSigner);
        address[] memory pool = new address[](16);
        for (uint256 j; j < 16; ++j) pool[j] = address(uint160(0x1000 + j));
        for (uint256 k; k < 60; ++k) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint8 league = uint8(seed % 2);
            h.recordDinger(league, pool[(seed >> 1) % 16], 375 + (seed >> 8) % 246);
        }
        _checkBoard(h, 0, pool);
        _checkBoard(h, 1, pool);
    }

    function test_boardResetsEachDay() public {
        DerbyHarness h = new DerbyHarness(address(imd), oracleSigner);
        h.recordDinger(0, address(0x1), 400);
        uint256 d0 = h.currentDay();
        vm.warp(block.timestamp + 1 days);
        h.recordDinger(0, address(0x2), 380);
        (address[] memory today, ) = h.board(0, h.currentDay());
        (address[] memory yesterday, ) = h.board(0, d0);
        assertEq(today.length, 1);
        assertEq(today[0], address(0x2));
        assertEq(yesterday[0], address(0x1));
    }

    // ───────── oracle settlement ─────────

    function _attestation(address[] memory ranked, bytes32 reqId, bytes32 q) internal view returns (SwarmDerby.Attestation memory a) {
        a = SwarmDerby.Attestation({
            requestId: reqId, chainId: 4663, questionHash: q, answerType: 4,
            answer: abi.encode(ranked), figure: 0, fromBlock: 1_001, toBlock: 1_500,
            blockHash: bytes32(uint256(1)), panelJobId: bytes32(uint256(2)),
            panelSize: 5, quorum: 4, agreed: 5, issuedAt: uint64(block.timestamp), expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _sign(SwarmDerby.Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(
            "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,"
            "bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,"
            "uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
        );
        bytes32 structHash = keccak256(bytes.concat(
            abi.encode(typeHash, a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock),
            abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", derby.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_settleEachLeagueFromItsOwnPot() public {
        arb.setBlock(2_000);
        _buy(player, 0, 100); // arcade pot 6.75
        _buy(player, 1, 100); // agent pot 6.75
        address[] memory ranked = new address[](4);
        ranked[0] = address(0x1); ranked[1] = address(0x2); ranked[2] = address(0x3); ranked[3] = address(0x4);
        SwarmDerby.Attestation memory a = _attestation(ranked, bytes32("req-1"), Q_ARCADE);
        address settler = address(0x5E77);
        bytes memory sig = _sign(a, oraclePk);
        vm.prank(settler);
        derby.settleDay(0, a, sig);
        assertEq(imd.balanceOf(settler), 0.030375 ether);
        assertEq(imd.balanceOf(address(0x1)), 3.626775 ether);
        assertEq(imd.balanceOf(address(0x2)), 1.51115625 ether);
        assertEq(imd.balanceOf(address(0x3)), 0.90669375 ether);
        assertEq(derby.pot(0), 0.675 ether);
        assertEq(derby.pot(1), 6.75 ether); // agent pot untouched
        assertEq(derby.lastSettledToBlock(0), 1_500);
        assertEq(derby.lastSettledToBlock(1), 1_000);

        sig = _sign(a, oraclePk);
        vm.expectRevert(abi.encodeWithSelector(SwarmDerby.BadAttestation.selector, "replayed"));
        derby.settleDay(0, a, sig);
    }

    function test_settleRejectsOtherLeaguesQuestion() public {
        arb.setBlock(2_000);
        _buy(player, 1, 10);
        address[] memory ranked = new address[](1);
        ranked[0] = address(0x1);
        SwarmDerby.Attestation memory a = _attestation(ranked, bytes32("req-x"), Q_ARCADE);
        bytes memory sig = _sign(a, oraclePk);
        vm.expectRevert(abi.encodeWithSelector(SwarmDerby.BadAttestation.selector, "question"));
        derby.settleDay(1, a, sig); // arcade answer can't pay the agent league
    }

    function test_settleAgentLeague() public {
        arb.setBlock(2_000);
        _buy(player, 1, 100);
        address[] memory ranked = new address[](1);
        ranked[0] = address(0x9);
        SwarmDerby.Attestation memory a = _attestation(ranked, bytes32("req-ag"), Q_AGENT);
        derby.settleDay(1, a, _sign(a, oraclePk));
        assertEq(imd.balanceOf(address(0x9)), 3.626775 ether);
    }

    function test_settleRejectsWrongSigner() public {
        arb.setBlock(2_000);
        _buy(player, 0, 10);
        address[] memory ranked = new address[](1);
        ranked[0] = address(0x1);
        SwarmDerby.Attestation memory a = _attestation(ranked, bytes32("req-2"), Q_ARCADE);
        bytes memory sig = _sign(a, 0xBAD);
        vm.expectRevert(abi.encodeWithSelector(SwarmDerby.BadAttestation.selector, "signer"));
        derby.settleDay(0, a, sig);
    }

    function test_settleRejectsWeakConsensus() public {
        arb.setBlock(2_000);
        _buy(player, 0, 10);
        address[] memory ranked = new address[](1);
        ranked[0] = address(0x1);
        SwarmDerby.Attestation memory a = _attestation(ranked, bytes32("req-3"), Q_ARCADE);
        a.agreed = 3;
        bytes memory sig = _sign(a, oraclePk);
        vm.expectRevert(abi.encodeWithSelector(SwarmDerby.BadAttestation.selector, "consensus"));
        derby.settleDay(0, a, sig);
    }

    function test_settleNeedsForwardProgress() public {
        _buy(player, 0, 10);
        address[] memory ranked = new address[](1);
        ranked[0] = address(0x1);
        arb.setBlock(2_000);
        SwarmDerby.Attestation memory a = _attestation(ranked, bytes32("req-4"), Q_ARCADE);
        derby.settleDay(0, a, _sign(a, oraclePk));
        SwarmDerby.Attestation memory b2 = _attestation(ranked, bytes32("req-5"), Q_ARCADE);
        bytes memory sig = _sign(b2, oraclePk);
        vm.expectRevert(abi.encodeWithSelector(SwarmDerby.BadAttestation.selector, "window"));
        derby.settleDay(0, b2, sig);
    }

    function test_initQuestionsOnce() public {
        SwarmDerby d = new SwarmDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.5 ether, oracleSigner, bytes32(0), bytes32(0));
        d.initQuestions(Q_ARCADE, Q_AGENT);
        vm.expectRevert(SwarmDerby.Timelocked.selector);
        d.initQuestions(bytes32("a"), bytes32("b"));
    }

    function test_oracleChangeTimelocked() public {
        derby.queueOracle(address(0xBEEF), bytes32("q1"), bytes32("q2"));
        vm.expectRevert(SwarmDerby.Timelocked.selector);
        derby.applyOracle();
        vm.warp(block.timestamp + 2 days);
        derby.applyOracle();
        (address s, , ) = derby.oracle();
        assertEq(s, address(0xBEEF));
    }

    // ───────── odds ─────────

    function _check(bytes32 seed, uint256 id, uint8 q, uint8 v, uint8 tier, uint16 feet) internal pure {
        (uint8 t, uint16 f) = DerbyOdds.roll(seed, id, q, v);
        assertEq(t, tier, "tier mismatch vs browser");
        assertEq(f, feet, "feet mismatch vs browser");
    }

    /// Vectors generated by the browser engine (derby-odds.js), including under-the-line swings.
    function test_parityWithBrowser() public pure {
        _check(0x1c23e8d8643fc8b51e62bc0b1fb0ec1e08ecb299c838482bf291d4f666660a35, 3, 1, 0, 3, 414);
        _check(0x7710f82db9ce885d7a0a8147a3e87f19a0968d1a6ad204aa28ceac5a23f67497, 7922, 13, 59, 3, 425);
        _check(0xa134f56094cb76efb035b5379cbb9bcfaf13115efdb755d861f524bdf722330b, 15841, 37, 60, 4, 465);
        _check(0xa681a5389008b59538a43ef6c08cf02ecda79cb9320bfaccd2458a219da38edf, 23760, 50, 100, 4, 524);
        _check(0x6ccc2948ae49d7278c39b891f42df195b103988ff0dc3b6b0daae102d3ec1588, 31679, 64, 0, 2, 190);
        _check(0x665b1bc67c927aa93cd275ecb32f4de75975b1ef0bed67e4f8be0fae1901163c, 39598, 88, 59, 3, 378);
        _check(0x3cec2cb000f18f4b201dcaf547eaa48cb4f2461b4d3bf20816180fee93c3d0cc, 47517, 100, 60, 2, 236);
        _check(0xf2e3873d9e719c4cb73118dcee89fd5930baf94cea3ace6d21a16450000e2d1f, 55436, 1, 100, 2, 247);
        _check(0xce2fba9f3212e3b3783a426e4ecc2643a7fee8d4716e09bca204e404c028fb8b, 63355, 13, 0, 3, 449);
        _check(0x6d5056a39b70996914c20d68a2692f322d0278ef9ca17d1c294a26ea7f4fba2a, 71274, 37, 59, 3, 440);
        _check(0xca76226d6abe7dea7cec743435334dc8d98a46f6dfb9f84dd3d653d9bb0b382b, 79193, 50, 60, 2, 299);
        _check(0x2ca2f66ebcfebc4775da6c71506ff472fd5b372d3d571458dc78c6d4e98e5441, 87112, 64, 100, 2, 228);
        _check(0xd9b85b290c48d15a00462555eeaf6e66c3f0aedacadd4bf8358aae8fbe29a92a, 95031, 88, 0, 3, 377);
        _check(0x5511c4275cf8e9c9e386a9fccdf1a81dae79d072f607c7113dd479c7a9cbc842, 102950, 100, 59, 3, 387);
        _check(0xc3aefba8ff89a31db551cb59e34eec827a895dc7df0c3a19142fa0b1a5da1708, 110869, 1, 60, 4, 546);
        _check(0x2f108138ca739ebe417b5128d8b7d707e2bbcd655688d749c07eb4680a4bd4dc, 118788, 13, 100, 2, 237);
        _check(0xaa1c73708a7f2a9d7ed3c265b76b14672d8edb9c252cb8371952eb2055fa36ac, 126707, 37, 0, 2, 272);
        _check(0xd8879ec0b3396f951c60af5c3a078abf5d391644d13c2b4b64460c6dc50bc064, 134626, 50, 59, 3, 396);
        _check(0xb43523d07096c44974d65630ddffa1e5c412d483eda286af5016106aa2e68104, 142545, 64, 60, 1, 144);
        _check(0x0403c6393804e8ef45a992359f16164a249b89eb39d71549b8836f79239744f2, 150464, 88, 100, 4, 495);
        _check(0x4fd4d3df6eadf2ab0ed756001b9d3c2100097baf4234edf045b3c7647a6d47d3, 158383, 100, 0, 3, 435);
        _check(0xf40ab9b46cd6cb5de2e2b640d841793efe8a0d9694c3a2f8559443916f734c10, 166302, 1, 59, 3, 413);
        _check(0x46eec7bf66945d1fb9c3a872be5fc6a8f69c7540a6db77ef4889950ab4afad49, 174221, 13, 60, 4, 538);
        _check(0xa673b26960417993bc9079ad3ab154bb57df68568172598b13df9cbd73096f68, 182140, 37, 100, 2, 253);
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

    function test_swingStoresVelo() public {
        vm.prank(player);
        derby.buyTurns(0, 1);
        uint256 id = _swing(80, 42, SALT);
        (, , , uint8 v, , , ) = derby.swings(id);
        assertEq(v, 42);
    }

    /// Expected home-run feet per swing is flat across quality (within rounding).
    function test_expectedValueFlat() public pure {
        for (uint8 q = 1; q <= 100; ++q) {
            uint256[5] memory c = DerbyOdds.thresholds(q);
            uint256 ev = (c[2] - c[1]) * 412 * 10 + (c[3] - c[2]) * 4995 + (c[4] - c[3]) * 585 * 10; // feet*10 * bps
            assertApproxEqAbs(ev / 10000, 2626, 2); // 262.6 ft
        }
    }

}
