use starknet::ContractAddress;

#[derive(Copy, Drop, Serde,starknet::Store, Hash, PartialEq)]
struct ConstellationOption{
    creator: ContractAddress,
    owner: ContractAddress,
    collateral_addr: ContractAddress,
    counter_offer_addr:ContractAddress,
    collateral_amount: u256,
    counter_offer_amount:u256,
    isBurned: bool,
    expires: u64,
}

#[starknet::interface]
trait IConstellaOption<TContractState> {
    fn mint(ref self: TContractState,collateral_addr: ContractAddress,collateral_amount: u256,counter_offer_addr:ContractAddress,counter_offer_amount:u256, expires: u64)->bool;
    fn Transfer(ref self: TContractState, id: u128,from:ContractAddress,to:ContractAddress) -> bool;
    fn Execute(ref self: TContractState, id: u128) -> bool;
    fn Burn(ref self: TContractState, id: u128) -> bool;
    fn cancel_expires_option(ref self: TContractState,id: u128) -> bool;
    fn approve_tansfer(ref self: TContractState, spender: ContractAddress,isapprove:bool);

    fn get_option_by_id(self:@TContractState,id:u128) -> ConstellationOption;
    fn get_ids_by_owner(self: @TContractState,owner: ContractAddress) -> Array<u128>;
    fn get_ids_by_creator(self: @TContractState,creator: ContractAddress) -> Array<u128>;

    fn transfer_owner(ref self: TContractState, to: ContractAddress);
}




#[starknet::contract]
mod constellation_contract {
    use starknet::{ContractAddress, get_caller_address,get_contract_address,get_block_info};
    use openzeppelin::token::erc20::interface::IERC20Dispatcher;
    use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
    use super::ConstellationOption;
    #[storage]
    struct Storage {
        owner: ContractAddress,
        options: LegacyMap::<u128,ConstellationOption>,
        owner_amount: LegacyMap::<ContractAddress,u32>,
        creator_amount: LegacyMap::<ContractAddress,u32>,
        // (onwer,spender)
        approve_list: LegacyMap::<(ContractAddress,ContractAddress),bool>,
        total_options: u128,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.total_options.write(0);
        self.owner.write(get_caller_address())
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Mint: Mint,
        Transfer:Transfer,
    }

    #[derive(Drop, starknet::Event)]
    struct Mint {
        #[key]
        id:u128,
        minter: ContractAddress,
    }
    #[derive(Drop, starknet::Event)]
    struct Transfer {
        #[key]
        id:u128,
        from: ContractAddress,
        to:ContractAddress,
    }


    
    #[external(v0)]
    impl constellation_contract of super::IConstellaOption<ContractState> {
        fn mint(ref self: ContractState,collateral_addr: ContractAddress,collateral_amount: u256,counter_offer_addr:ContractAddress,counter_offer_amount:u256, expires: u64)->bool{
            let mut Coption = ConstellationOption {creator: get_caller_address(),owner: get_caller_address(),collateral_addr: collateral_addr, counter_offer_addr: counter_offer_addr,collateral_amount: collateral_amount,counter_offer_amount: counter_offer_amount,isBurned:false, expires:expires};
            let mut total_options = self.total_options.read();
            let mut owner_amount = self.owner_amount.read(get_caller_address());
            let mut creator_amount = self.creator_amount.read(get_caller_address());
            let mut thisAddr = get_contract_address();
            let issucces = IERC20Dispatcher{contract_address:collateral_addr}.transfer_from(get_caller_address(),get_contract_address(),collateral_amount);
            assert(issucces,  'TRANSFER_ERROR');
            self.options.write(total_options,Coption);
            self.total_options.write(total_options+1);
            self.owner_amount.write(get_caller_address(),owner_amount+1);
            self.creator_amount.write(get_caller_address(),creator_amount+1);
            self.emit(Mint{id:total_options, minter:get_caller_address()});
            true
        }
        fn Transfer(ref self: ContractState, id: u128,from:ContractAddress,to:ContractAddress)->bool{
            let mut total_options = self.total_options.read();
            assert(id<total_options,'the token is not found');
            let mut Coption = self.options.read(id);
            let old_owner = Coption.owner;
            let mut isApprove = false;
            if get_caller_address() ==old_owner{
                isApprove = true;
            }
            let approve = self.approve_list.read((from,get_caller_address()));
            if approve {
                isApprove = true;
            } 
            assert(isApprove, 'you didnot get approve');
            Coption.owner = to;
            let mut owner_amount = self.owner_amount.read(from);
            let mut to_amount = self.owner_amount.read(to);
            self.owner_amount.write(from,owner_amount-1);
            self.owner_amount.write(to,owner_amount+1);
            self.options.write(id,Coption);
            self.emit(Transfer{id:id,from:from,to:to});
            true
        }
        fn Execute(ref self: ContractState, id: u128) -> bool{
            let mut Coption = self.options.read(id);
            let owner = Coption.owner;
            assert(owner==get_caller_address(),'YOU_ARE_NOT_THE_OWNER');
            assert(!Coption.isBurned,'OPTION_IS_BURED');
            assert(Coption.expires>get_block_info().unbox().block_timestamp,'OPTION_IS_EXPIRED');
            Coption.isBurned = true;
            self.options.write(id,Coption);
            let issucces = IERC20Dispatcher{contract_address:Coption.counter_offer_addr}.transfer_from(get_caller_address(),Coption.creator,Coption.counter_offer_amount);
            assert(issucces,  'TRANSFER_FROM_ALLOWANCE');
            let issucces = IERC20Dispatcher{contract_address:Coption.collateral_addr}.transfer_from(get_contract_address(),owner,Coption.collateral_amount*997/1000);
            let issucces = IERC20Dispatcher{contract_address:Coption.collateral_addr}.transfer_from(get_contract_address(),self.owner.read(),Coption.collateral_amount*3/1000);
            assert(issucces,  'TRANSFER_FROM_ALLOWANCE');
            true
        } 
        fn Burn(ref self: ContractState, id: u128) -> bool{
            let mut Coption = self.options.read(id);
            let owner = Coption.owner;
            assert(owner==get_caller_address(),'YOU_ARE_NOT_THE_OWNER');
            assert(!Coption.isBurned,'OPTIONS_ALREADY_BURN');
            Coption.isBurned=true;
            self.options.write(id,Coption);
            let issucces = IERC20Dispatcher{contract_address:Coption.collateral_addr}.transfer_from(get_contract_address(),Coption.creator,Coption.collateral_amount);
            assert(issucces,  'TRANSFER_FROM_ALLOWANCE');
            true
        }

        fn cancel_expires_option(ref self: ContractState,id: u128) -> bool{
            let mut Coption = self.options.read(id);
            assert(!Coption.isBurned,'OPTION_IS_BURED');
            assert(Coption.expires<get_block_info().unbox().block_timestamp,'OPTION_IS_NOT_EXPIRED');
            Coption.isBurned=true;
            self.options.write(id,Coption);
            let issucces = IERC20Dispatcher{contract_address:Coption.collateral_addr}.transfer_from(get_contract_address(),Coption.creator,Coption.collateral_amount);
            assert(issucces,  'TRANSFER_FROM_ALLOWANCE');
            true
        }
        fn approve_tansfer(ref self: ContractState, spender: ContractAddress, isapprove:bool){
            self.approve_list.write((get_caller_address(),spender),isapprove)
        }
        fn get_option_by_id(self:@ContractState,id:u128) -> ConstellationOption{
            let Coption = self.options.read(id);
            Coption
        }
        fn get_ids_by_owner(self: @ContractState,owner: ContractAddress) -> Array<u128>{
            let total_amount = self.total_options.read();
            let owner_amount = self.owner_amount.read(owner);
            let mut resp = ArrayTrait::<u128>::new();
            let mut i:u128 = 0;
            let mut found_amount = 0;
            loop{
                if(i>=total_amount){
                    break;
                }
                if(found_amount >= owner_amount){
                    break;
                }
                let Coption = self.options.read(i);
                if Coption.owner == owner{
                    resp.append(i);
                    found_amount = found_amount+1;
                }
                i = i+1;
            };
            resp
        }
        
        fn get_ids_by_creator(self: @ContractState,creator: ContractAddress) -> Array<u128>{
            let total_amount = self.total_options.read();
            let creator_amount = self.creator_amount.read(creator);
            let mut resp = ArrayTrait::<u128>::new();
            let mut i:u128 = 0;
            let mut found_amount = 0;
            loop{
                if(i>=total_amount){
                    break;
                }
                if(found_amount >= creator_amount){
                    break;
                }
                let Coption = self.options.read(i);
                if Coption.creator == creator{
                    resp.append(i);
                    found_amount = found_amount+1;
                }
                i = i+1;
            };
            resp
        }
        fn transfer_owner(ref self: ContractState, to: ContractAddress){
            assert(get_caller_address()==self.owner.read(),'YOU_CANNOT_DO_THAT');
            self.owner.write(to);
        }

    }
}