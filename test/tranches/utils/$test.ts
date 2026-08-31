import { $bigint } from 'dequanto/utils/$bigint';
import { $number } from 'dequanto/utils/$number';
import { $require } from 'dequanto/utils/$require';

export namespace $test {

    export function eqDiff (a: bigint, b: bigint, diffExpected: bigint, msg?: string)
    export function eqDiff (a: number, b: number, diffExpected: number, msg?: string)
    export function eqDiff (a: number | bigint, b: number | bigint, diffExpected: number | bigint, msg: string = '') {
        let diff = typeof a === 'bigint'
            ? $bigint.abs((a as bigint) - (b as bigint))
            : Math.abs((a as number) - (b as number))
            ;
        let text = `Difference between ${a} and ${b} is too large: ${diff}; ${msg}`;
        $require.lte(diff, diffExpected, text);
    }

    export function compare (a: bigint | number, b: bigint | number, decimals?: number, msg?: string) {
        let aNum = typeof a === 'bigint'
            ? $bigint.toEther(a, decimals ?? 18)
            : a;
        let bNum = typeof b === 'bigint'
            ? $bigint.toEther(b, decimals ?? 18)
            : b;

        const diffExpected = aNum > 1000
            ? aNum * 0.000001 // 0.0001%
            : 0.001
        const round = aNum > 1000 ? 0 : 3;
        return eqDiff(
            $number.round(aNum, round, 'round'),
            $number.round(bNum, round, 'round'),
            diffExpected,
            msg
        );
    }
}
