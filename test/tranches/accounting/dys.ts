import { DYSAccounting } from '@0xc/hardhat/DYSAccounting/DYSAccounting';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { Deployments } from 'dequanto/contracts/deploy/Deployments';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { IAccount } from 'dequanto/models/TAccount';
import { TEth } from 'dequanto/models/TEth';
import { $bigint } from 'dequanto/utils/$bigint';
import { $date } from 'dequanto/utils/$date';
import { $require } from 'dequanto/utils/$require';

export namespace dys {

    const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
    const hh = new HardhatProvider();

    let snapshot;

    export let client: Web3Client = hh.client();
    export let deployer: IAccount = hh.deployer();

    export let cdo;
    export let cdoAccount: IAccount;
    export let accounting: DYSAccounting;


    const ds = new Deployments(client, deployer, {});

    export async function deploy() {

        const { contract: cdoMock } = await hh.deployCode(
            `
                    contract MockCDO {
                        uint256 public _rate = 1e18;
                        uint256 public _nav = 0;

                        int64 public _aprTarget = 0;
                        int64 public _aprBase = 0.1e12;

                        function setTotalAssets(uint256 amount) external {
                            _nav = amount;
                        }
                        function setRate(uint256 rate) external {
                            _rate = rate;
                        }
                        function setAprs(int64 aprTarget, int64 aprBase) external {
                            _aprTarget = aprTarget;
                            _aprBase = aprBase;
                        }
                        function assetsFlow(int256 amount) external {
                            _nav = amount > 0
                                ? _nav + uint256(amount)
                                : _nav - uint256(-amount);
                        }
                        function totalStrategyAssets() public view returns (uint256) { return _nav; }
                        function totalStrategyAssets(uint256, uint256) public view returns (uint256) { return _nav; }
                        function totalStrategyAssetsSnapshot (uint256, uint256) public view returns (uint256, uint256, uint256, uint256) {
                            return (_nav, block.timestamp, _nav, block.timestamp);
                        }

                        function strategy() public view returns (address) { return address(this); }

                        function latestRoundData () public view returns (int64, int64, uint64, uint64) {
                            return (_aprTarget, _aprBase, uint64(block.timestamp), 1);
                        }
                    }
                `,
            { client },
        );

        cdo = cdoMock;
        cdoAccount = {
            address: cdoMock.address,
            type: 'impersonated'
        } as TEth.IAccount;

        await client.debug.setBalance(cdoAccount.address, BigInt(1e18));

        await deployAccounting({
            useJuniorCoversPaidSrtProjection: true
        });

        snapshot = await client.debug.snapshot();
        return {
            client,
            accounting,
            deployer,
            revert
        }
    }

    export async function revert() {
        await client.debug.revert(snapshot);
        snapshot = await client.debug.snapshot();
    }

    export async function deployAccounting(params: {
        useJuniorCoversPaidSrtProjection: boolean
    }) {
        const { contract: dysAccounting } = await ds.ensureWithProxy(DYSAccounting, {
            id: `DYSAccounting-${params.useJuniorCoversPaidSrtProjection}`,
            arguments: [
                18n,
                false,
                true,
                false,
                params.useJuniorCoversPaidSrtProjection,
                false,
            ],
            initialize: [
                deployer.address,
                cdo.address,
                cdo.address,
                cdo.address,
            ]
        });
        await dysAccounting.storage.$set('riskX', .5e18);
        await dysAccounting.storage.$set('riskY', 0);

        accounting = dysAccounting;
    }


    // HELPERS

    export async function totalAssets () {
        const { jrtNavT1Projected, reserveNavT1, srtNavT1 } = await accounting.totalAssets();
        return jrtNavT1Projected + reserveNavT1 + srtNavT1;
    }

    export async function deposit(jrtAssetsInMix: bigint | number, srtAssetsInMix: bigint | number) {
        const jrtAssetsIn = toWei(jrtAssetsInMix);
        const srtAssetsIn = toWei(srtAssetsInMix);
        await accounting.$receipt().updateAccounting(cdoAccount);
        await accounting.$receipt().updateBalanceFlow(cdoAccount, jrtAssetsIn, 0n, srtAssetsIn, 0n);
        await cdo.$receipt().assetsFlow(deployer, jrtAssetsIn + srtAssetsIn);
    }
    export async function redeem(jrtAssetsOutMix: bigint | number, srtAssetsOutMix: bigint | number) {
        const jrtAssetsOut = toWei(jrtAssetsOutMix);
        const srtAssetsOut = toWei(srtAssetsOutMix);
        await accounting.$receipt().updateAccounting(cdoAccount);
        await accounting.$receipt().updateBalanceFlow(cdoAccount, 0n, jrtAssetsOut, 0n, srtAssetsOut);
        await cdo.$receipt().assetsFlow(deployer, -jrtAssetsOut - srtAssetsOut);
    }
    export async function updateAccounting() {
        await accounting.$receipt().updateAccounting(cdoAccount);
    }
    export async function distribute(time: string, aprTVL: number) {
        const nav = await cdo._nav();
        const rate = await cdo._rate();

        const dt = await $date.parseTimespan(time, { get: 's' });


        let apr = $bigint.toWei(aprTVL, 12);
        let navT1 = nav + nav * apr * BigInt(dt) / BigInt(SECONDS_PER_YEAR) / 10n ** 12n;

        await cdo.$receipt().setTotalAssets(deployer, navT1);
        await updateAccounting();
    }
    export async function distributeAbs(rewardsTVL: bigint | number) {
        const nav = await cdo._nav();
        const navT1 = nav + toWei(rewardsTVL);

        await cdo.$receipt().setTotalAssets(deployer, navT1);
        await updateAccounting();
    }
    export async function forceReconciliation() {
        await distributeAbs(1001n);
    }
    export async function expectApprox(jrt: number, srt: number) {
        const assets = await accounting.totalAssets();
        const jrtFact = $bigint.toEther(assets.jrtNavT1Projected, 18, 1);
        const srtFact = $bigint.toEther(assets.srtNavT1, 18, 1);

        const jrtFactDiff = Math.abs(jrt - jrtFact);
        const srtFactDiff = Math.abs(srt - srtFact);
        $require.lte(jrtFactDiff, .5, `JRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
        $require.lte(srtFactDiff, .5, `SRT should be approximately equal | ${jrt}, ${srt} != ${jrtFact}, ${srtFact}`);
    }
    export async function mine(time: string) {
        await client.debug.mine(time);
    }
    export async function time() {
        return (await client.getBlock('latest')).timestamp;
    }
    function toWei(n: bigint | number) {
        if (typeof n === 'number') {
            return $bigint.toWei(n, 18);
        }
        return n;
    }

}
