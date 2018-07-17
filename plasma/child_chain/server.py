import click

from werkzeug.wrappers import Request, Response
from werkzeug.serving import run_simple
from jsonrpc import JSONRPCResponseManager, dispatcher
from plasma.child_chain.child_chain import ChildChain
from plasma.config import plasma_config
from plasma.root_chain.deployer import Deployer

root_chain = None
token = None
child_chain = None


@Request.application
def application(request):
    # Dispatcher is dictionary {<method_name>: callable}
    dispatcher["submit_block"] = lambda block: child_chain.submit_block(block)
    dispatcher["apply_transaction"] = lambda transaction: child_chain.apply_transaction(transaction)
    dispatcher["get_transaction"] = lambda blknum, txindex: child_chain.get_transaction(blknum, txindex)
    dispatcher["get_current_block"] = lambda: child_chain.get_current_block()
    dispatcher["get_current_block_num"] = lambda: child_chain.get_current_block_num()
    dispatcher["get_block"] = lambda blknum: child_chain.get_block(blknum)
    response = JSONRPCResponseManager.handle(
        request.data, dispatcher)
    return Response(response.json, mimetype='application/json')


@click.command()
@click.option('--root_chain_address', help="The ethereum address of the root chain smart contract")
@click.option('--pdex_token_address', help="The ethereum address of the PDEX token smart contract")
def main(root_chain_address, pdex_token_address):
    root_chain = Deployer().get_contract_at_address("RootChain", root_chain_address, concise=False)
    token = Deployer().get_contract_at_address("PDEXToken", pdex_token_address, concise = False)
    child_chain = ChildChain(root_chain, token)

    run_simple('localhost', 8546, application)
    

if __name__ == '__main__':
    main()
