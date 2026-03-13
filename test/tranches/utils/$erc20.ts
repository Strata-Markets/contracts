import memd from'memd';
import { TEth } from 'dequanto/models/TEth';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { $bigint } from 'dequanto/utils/$bigint';
import { $require } from 'dequanto/utils/$require';
import { $acc } from './$acc';
import { $hh } from './$hh';
import { l } from 'dequanto/utils/$logger';
import alot from 'alot';
import { $hex } from 'dequanto/utils/$hex';
import { File } from 'atma-io';

export namespace $erc20 {

    export async function mint (erc20: any, minter: TEth.IAccount, receiver: $acc.Address, amount: bigint | number): Promise<void> {
        let amountWei = await toAmount(erc20, amount);
        let receiverAddr = $acc.toAddress(receiver);
        await erc20.$receipt().mint(minter, receiverAddr, amountWei);
    }

    export async function toAmount (token: $acc.Address, amount: bigint | number | `${number}%`, account?: $acc.Address): Promise<bigint> {
        if (typeof amount === 'bigint') {
            return amount;
        }
        let erc20 = new ERC20($acc.toAddress(token), $hh.getClient());
        if (typeof amount === 'number') {
            return $bigint.toWei(amount, await Tools.decimals(erc20))
        }
        if (amount.endsWith('%')) {
            let p = Number(/^\d+/.exec(amount)[0]);
            let user = $acc.toAddress(account);
            let balance = await erc20.balanceOf(user);
            return $bigint.multWithFloat(balance, p / 100);
        }
        throw new Error(`Invalid amount format: ${amount}`);
    }

    export async function transfer (erc20: ERC20 | any, from, to, amount: bigint | number | `${number}%`): Promise<any> {
        let amountWei = await toAmount(erc20, amount, from);
        await erc20.$receipt().transfer(from, to, amountWei);
    }

    export async function eqBalance(erc20: ERC20 | any, account: $acc.Address, amount: bigint | number, message?: string) {
        return eqBalanceDiff(erc20, account, amount, 0n, message);
    }

    export async function eqBalanceDiff(erc20: ERC20 | any, account: $acc.Address, amount: bigint | number, maxDiffWei: bigint, message?: string) {
        let decimals = await erc20.decimals();
        let amountWei = typeof amount === 'number'
            ? $bigint.toWei(amount, decimals)
            : amount;

        let address = $acc.toAddress(account);

        let balanceWei = await erc20.balanceOf(address);

        let amountEth = $bigint.toEther(amountWei, decimals);
        let balanceEth = $bigint.toEther(balanceWei, decimals);
        let diffWei = $bigint.abs(amountWei - balanceWei);

        $require.lte(diffWei, maxDiffWei, `"${await erc20.symbol()}" balance missmatch for user "${address}" (${amountEth} != ${balanceEth}) ${message ?? ''}`);
        return amountWei;
    }

    export async function decimals(erc20: ERC20): Promise<number> {
        return Tools.decimals(erc20);
    }

    export async function setBalanceAny (erc20: ERC20, account: $acc.Address, amount: bigint | number) {
        const client = erc20.client;
        $require.eq(client.platform, 'hardhat');
        const address = $acc.toAddress(account);
        const rpc = await client.getRpc();

        const req = await (erc20.$data() as any).balanceOf(address);
        const balanceTrace = await rpc.request({
            method: 'debug_traceCall',
            params: [
                req,
                'latest',
                {
                    disableMemory: true,
                    disableStack: true,
                    disableStorage: false,
                }
            ]
        }) as {
            returnValue: TEth.Hex
            failed: boolean
            structLogs: {
                "op": "RETURN",
                "pc": 1698,
                "storage": Record<string, TEth.Hex>
            }[]
        };

        $require.True(balanceTrace.failed === false, `erc20 balance retrieval failed for ${await erc20.symbol()}`);
        let returnOp = alot(balanceTrace.structLogs.reverse()).find(x => x.op === 'RETURN');
        $require.notNull(returnOp, `RETURN opcode not found`);
        $require.notNull(returnOp.storage, `Storage not found`);

        let returnValue = $hex.raw(balanceTrace.returnValue);
        let slots = alot.fromObject(returnOp.storage).filter(x => x.value === returnValue).toArray();
        $require.gt(slots.length, 0, `Slot not found`);
        let SLOT = $hex.ensure(slots[slots.length - 1].key);

        let balance = typeof amount === 'number'
            ? await $bigint.toWei(amount, await Tools.decimals(erc20))
            : amount;

        await client.debug.setStorageAt(erc20.address, SLOT, $bigint.toHex(balance));
    }

    class Tools {
        // Use a low maxAge because HH resets can redeploy tokens with different decimals.
        // (i) Redeployments may reuse the same address when the EOA nonce is reset.
        @memd.deco.memoize({ keyResolver: x => x.address, maxAge: 0.5 })
        static async decimals (erc20: ERC20) {
            return await erc20.decimals();
        }
    }
}
