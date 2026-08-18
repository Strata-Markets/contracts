import { MockNestVaultPredicateProxy } from '@0xc/hardhat/MockNestVaultPredicateProxy/MockNestVaultPredicateProxy';
import { Addresses } from '@s/constants';
import { $abiCoder } from 'dequanto/abi/$abiCoder';
import { TEth } from 'dequanto/models/TEth';
import { $http } from 'dequanto/utils/$http';
import { $require } from 'dequanto/utils/$require';

const NEST_API = `https://api.nest.credit/v1/actions/vaults/nest-opal-vault/mint/build-tx`;

type TBuildTxResult = {
    "data": {
        "feeAmount": "0",
        "transactions": [
            {
                "label": "approve",
                "to": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                "data": TEth.Hex
            },
            {
                "label": "deposit",
                "description": "Deposit into NestVault 0xd258029cf5a177e3306e09fbea63424543a505c0 via NestVaultPredicateProxy",
                "to": "0xfc0c4222b3a0c9b060c0b959dec62442036b9035",
                "data": TEth.Hex
            }
        ]
    }
}

export class NestUsdcParamsResolver {
    async getPredicateMessage(account: TEth.Address, amount: bigint) {
        const body = {
            "depositAsset": Addresses.eth.USDC,
            "depositAmount": amount.toString(),
            "chainId": 1,
            "recipient": account,
            "skipSimulation": true
        };

        const { data: json } = await $http.post<TBuildTxResult>({
            url: NEST_API,
            body
        });

        let tx = json.data.transactions[1];
        $require.eq(tx?.label, 'deposit');

        let predicateProxy = new MockNestVaultPredicateProxy();
        let data = tx.data;

        let params = predicateProxy.$parseInputData(data);
        let predicateMessage = params.params.predicateMessage;

        let predicateMessageBytes = $abiCoder.encode(
            [
                'tuple(string taskId,uint256 expireByBlockNumber,address[] signerAddresses,bytes[] signatures)'
            ],
            [predicateMessage]
        );

        return {
            bytes: predicateMessageBytes
        };
    }
}


// const mockDepositTx = `0xa46ea103000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000004c4b400000000000000000000000008a646edc4633adba5ec87dedaf3af958e268fe96000000000000000000000000d258029cf5a177e3306e09fbea63424543a505c000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000006a4f8f3c00000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000002461376634363561632d643361342d343066312d613237652d6362653561366632343661330000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005f936c12e43181662e85814b0cfd10334a33e5a10000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000412a981db652b205b5df933395961a24bfe58e8795f11b7764a2e8c46984499792518771ad983ab1a4b9099bfe09089f4d1f6d915bc3a6df3b99246b131683559f1c00000000000000000000000000000000000000000000000000000000000000`;
