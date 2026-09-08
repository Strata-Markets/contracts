import { Deployments } from 'dequanto/contracts/deploy/Deployments'
import { TEth } from 'dequanto/models/TEth'

export type TAccountingFactory = (params: {
    ds: Deployments,
    cdo,
    deployer: TEth.IAccount,
    options?: {
        useJuniorCoversPaidSrtProjection?: boolean
    }
}) => Promise<{ accounting }>;
