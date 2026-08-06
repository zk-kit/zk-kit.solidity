import { task, types } from "hardhat/config"
import poseidonSolidity from "poseidon-solidity"
import { proxy } from "poseidon-solidity"
import { ethers } from "ethers"
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers"
import { LazyIMT__factory } from "../typechain-types"

// based of: https://github.com/chancehudson/poseidon-solidity?tab=readme-ov-file#deploy
export async function deployPoseidon(
    provider: ethers.Provider,
    sender: ethers.Signer | HardhatEthersSigner,
    arity: number
) {
    const poseidon = (poseidonSolidity as any)[`PoseidonT${arity + 1}`]
    const proxyDoesNotExist = (await provider.getCode(proxy.address)) === "0x"
    const poseidonDoesNotExist = (await provider.getCode(poseidon.address)) === "0x"

    // First check if the proxy exists
    if (proxyDoesNotExist) {
        // fund the keyless account
        await sender.sendTransaction({
            to: proxy.from,
            value: proxy.gas
        })
        // then send the presigned transaction deploying the proxy
        await provider.broadcastTransaction(proxy.tx)
    }

    // Then deploy the hasher, if needed
    if (poseidonDoesNotExist) {
        //readme is wrong having typo here: send.sendTransaction instead of sender
        await sender.sendTransaction({
            to: proxy.address,
            data: poseidon.data
        })
    }

    return poseidon.address
}

task("deploy:imt-test", "Deploy an IMT contract for testing a library")
    .addParam<string>("library", "The name of the library", undefined, types.string)
    .addOptionalParam<boolean>("logs", "Print the logs", true, types.boolean)
    .addOptionalParam<number>("arity", "The arity of the tree", 2, types.int)
    .setAction(async ({ logs, library: libraryName, arity }, { ethers }): Promise<any> => {
        const provider = ethers.provider
        const [sender] = await ethers.getSigners()
        const poseidonAddress = await deployPoseidon(provider, sender, arity)

        if (logs) {
            console.info(`PoseidonT${arity + 1} library has been deployed to: ${poseidonAddress}`)
        }

        const LibraryFactory = (await ethers.getContractFactory(libraryName, {
            libraries: {}
        })) as LazyIMT__factory

        const library = await LibraryFactory.deploy()
        const libraryAddress = await library.getAddress()

        if (logs) {
            console.info(`${libraryName} library has been deployed to: ${libraryAddress}`)
        }

        const ContractFactory = await ethers.getContractFactory(`${libraryName}Test`, {
            libraries: {
                [libraryName]: libraryAddress
            }
        })

        const contract = await ContractFactory.deploy()
        const contractAddress = await contract.getAddress()

        if (logs) {
            console.info(`${libraryName}Test contract has been deployed to: ${contractAddress}`)
        }
        return { library, contract }
    })
