module enfi::magic_party {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;
    use aptos_token::token::{Self, TokenId, create_token_id_raw, withdraw_token};
    use std::signer::address_of;
    use std::bcs::to_bytes;
    use aptos_std::type_info::type_name;
    use aptos_token::property_map;
    use std::vector;
    use aptos_framework::account::create_resource_account;

    #[test_only]
    use aptos_token::token::{create_collection_script, create_token_script};
    #[test_only]
    use aptos_framework::account::create_account_for_test;
    #[test_only]
    use aptos_std::debug::print;

    struct VaultSignerCap has key {
        signer_cap: account::SignerCapability,
    }

    // This struct stores the token receiver's address and token_data_id in the event of token minting
    struct TokenMintingEvent has drop, store {
        token_receiver_address: address,
        token_id: TokenId,
        candyball_token_id : TokenId
    }

    // event emit when user stake their nft
    struct TokenStakeEvent has drop, store {
        token_id: TokenId,
        escrow_token_id: TokenId,
    }

    // This struct stores user's token relevant information
    struct EscrowMinter has key {
        expiration_timestamp: u64,
        minting_enabled: bool,
        collection_name: String,
        token_name_prefix: vector<u8>,
        token_uri_prefix: vector<u8>,
        counter: u64,
        collection_limit_creators: vector<address>,
        collection_limit_names: vector<String>,
        token_stake_events: EventHandle<TokenStakeEvent>
    }


    // this struct stores user's candyball information
    struct CandyballMinter has key {
        collection_name: String,
        token_name_prefix: vector<u8>,
        counter: u64,
        token_mint_events: EventHandle<TokenMintingEvent>
    }

    /// Action not authorized because the signer is not the owner of this module
    const ENOT_AUTHORIZED: u64 = 1;
    /// The collection minting is expired
    const ECOLLECTION_EXPIRED: u64 = 2;
    /// The collection minting is disabled
    const EMINTING_DISABLED: u64 = 3;
    /// Specified public key is not the same as the collection token minter's public key
    const EWRONG_PUBLIC_KEY: u64 = 4;
    /// stake time not enough
    const ESTAKE_TIME_NOT_ENOUGH: u64 = 5;

    const ESTAKE_COLLECTION_NOT_MATCH: u64 = 6;

    ///user need to wait for STAKING_TIME * seconds to claim their nft and enchanter airdrop token
    const STAKING_TIME: u64 = 7 * 24 * 60 * 60;
    //const EXPIRE_TIME: u64 = STAKING_TIME;
    const NUM_VEC: vector<u8> = b"0123456789";

    /// Initialize this module: create a resource account, two collections
    fun init_module(admin: &signer) acquires EscrowMinter {
        // Escrow
        let escrow_collection_name = string::utf8(
            b"Enchanter Magic Party Certificate NFT Collection"
        );
        let escrow_description = string::utf8(
            b"Proof-of-Stake tokens validating your 7-day NFT staking reward. Burn it to unstake your original NFT and claim the airdrop."
        );
        let escrow_collection_uri = string::utf8(
            b"https://enchanter-fi.s3.us-west-1.amazonaws.com/nft/collection-cover-certificate.png"
        );
        let escrow_token_name_prefix = b"Enchanter Magic Party Certificate #";
        let escrow_token_uri_prefix = b"EnchanterMagicPartyCertificate-";

        // Candy Ball
        let candyball_collection_name = string::utf8(
            b"Enchanter Candy Ball NFT Collection"
        );
        let candyball_description = string::utf8(
            b"Utility NFTs for airdrop claiming."
        );
        let candyball_collection_uri = string::utf8(
            b"https://enchanter-fi.s3.us-west-1.amazonaws.com/nft/collection-cover-candy-ball.png"
        );
        let candyball_token_name_prefix = b"Enchanter Candy Ball #";

        // create the nft collection
        let mutate_setting = vector<bool>[ false, false, false ];

        let (resource_signer, resource_signer_cap) = create_resource_account(admin, vector::empty<u8>());
        move_to(admin, VaultSignerCap {
            signer_cap: resource_signer_cap
        });

        token::create_collection(&resource_signer, escrow_collection_name, escrow_description, escrow_collection_uri, 1024, mutate_setting);
        token::create_collection(&resource_signer, candyball_collection_name, candyball_description, candyball_collection_uri, 1024, mutate_setting);

        move_to(admin, EscrowMinter {
            //token_data_id,
            expiration_timestamp: 0,
            minting_enabled: false,
            token_stake_events: account::new_event_handle(&resource_signer),
            collection_name: escrow_collection_name,
            token_name_prefix: escrow_token_name_prefix,
            token_uri_prefix: escrow_token_uri_prefix,
            counter: 1,
            collection_limit_creators: vector::empty(),
            collection_limit_names: vector::empty()
        });

        move_to(admin, CandyballMinter {
            collection_name: candyball_collection_name,
            token_name_prefix: candyball_token_name_prefix,
            counter: 1,
            token_mint_events: account::new_event_handle(&resource_signer)
        });

        // set_stake_enabled(admin, true);
        set_collections(
            admin,
            vector<address>[
                //aptos Monkeys
                @nft_aptosmonkeys,
                //Aptomingos
                @nft_Aptomingos,
                //Pontemite Space Pirates
                @nft_Pirates
            ],
            vector<String>[
                string::utf8(b"Aptos Monkeys"),
                string::utf8(b"Aptomingos"),
                string::utf8(b"Pontem Space Pirates")
            ]
        );
    }

    /// Set if minting is enabled for this collection token minter
    public entry fun set_stake_enabled(minter: &signer, minting_enabled: bool) acquires EscrowMinter {
        let minter_address = signer::address_of(minter);
        assert!(minter_address == @enfi, error::permission_denied(ENOT_AUTHORIZED));
        let collection_token_minter = borrow_global_mut<EscrowMinter>(minter_address);
        collection_token_minter.minting_enabled = minting_enabled;
        if(minting_enabled == true && collection_token_minter.expiration_timestamp == 0) {
            collection_token_minter.expiration_timestamp = timestamp::now_seconds() + STAKING_TIME;
        };
        if(minting_enabled == false) {
            collection_token_minter.expiration_timestamp = 0;
        };
    }

    public fun set_collections(admin: &signer, collection_creators: vector<address>, collection_names: vector<String>) acquires EscrowMinter {
        let minter_address = signer::address_of(admin);
        assert!(minter_address == @enfi, error::permission_denied(ENOT_AUTHORIZED));
        let minter = borrow_global_mut<EscrowMinter>(address_of(admin));
        minter.collection_limit_creators = collection_creators;
        minter.collection_limit_names = collection_names;
    }

    fun check_collection(
        collection_limit_creators: &vector<address>,
        collection_limit_names: &vector<String>,
        creators_address: &address,
        collection_name: &String
    ) {
        if(vector::length(collection_limit_creators) != 0) {
            let (isCreator, _) = vector::index_of(collection_limit_creators, creators_address);
            assert!(isCreator, error::aborted(ESTAKE_COLLECTION_NOT_MATCH));
        };

        if(vector::length(collection_limit_names) != 0) {
            let (isCollection, _) = vector::index_of(collection_limit_names, collection_name);
            assert!(isCollection, error::aborted(ESTAKE_COLLECTION_NOT_MATCH));
        };
    }

    /// stake famous nft 7 days and Mint an NFT to the receiver.
    public entry fun stake(
        receiver: &signer,
        creators_address: address,
        collection: String,
        name: String,
        property_version: u64
    ) acquires EscrowMinter, VaultSignerCap {
        //let receiver_addr = signer::address_of(receiver);
        // get the collection minter and check if the collection minting is disabled or expired
        let escrow_minter = borrow_global_mut<EscrowMinter>(@enfi);
        let now = timestamp::now_seconds();
        assert!(
            escrow_minter.expiration_timestamp == 0 || now < escrow_minter.expiration_timestamp,
            error::permission_denied(ECOLLECTION_EXPIRED)
        );
        assert!(escrow_minter.minting_enabled, error::permission_denied(EMINTING_DISABLED));

        check_collection(&escrow_minter.collection_limit_creators, &escrow_minter.collection_limit_names, &creators_address, &collection);

        // mint token to the receiver
        let signer_cap = &borrow_global<VaultSignerCap>(@enfi).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);

        let cnt_str = intToString(escrow_minter.counter);
        let token_name = string::utf8(escrow_minter.token_name_prefix);
        string::append(&mut token_name, cnt_str);

        let token_uri = string::utf8(
            b"https://enchanter-fi.s3.us-west-1.amazonaws.com/nft/"
        );
        string::append(&mut token_uri, string::utf8(escrow_minter.token_uri_prefix));
        string::append(&mut token_uri, cnt_str);
        string::append(&mut token_uri, string::utf8(b".png")); // Must be `PNG`

        // Move Counter to the next.
        escrow_minter.counter = escrow_minter.counter + 1;

        //create a token data id to specify which token will be minted
        let token_data_id = token::create_tokendata(
            &resource_signer,
            escrow_minter.collection_name,
            token_name,
            string::utf8(b""), // Token Description
            1,
            token_uri,
            address_of(&resource_signer),
            1,
            0,
            // we don't allow any mutation to the token
            token::create_token_mutability_config(
                &vector<bool>[ false, false, false, false, true ]
            ),
            vector<String> [
                string::utf8(b"mint_time"),
                string::utf8(b"creators_address"),
                string::utf8(b"collection"),
                string::utf8(b"name"),
                string::utf8(b"property_version")
            ],
            vector<vector<u8>> [
                to_bytes(&now),
                to_bytes(&creators_address),
                to_bytes(&collection),
                to_bytes(&name),
                to_bytes(&property_version)
            ],
            vector<String> [
                type_name<u64>(),
                type_name<address>(),
                type_name<String>(),
                type_name<String>(),
                type_name<u64>()
            ],
        );

        //mint and transfer escrow
        let escrow_token_id = token::mint_token(&resource_signer, token_data_id, 1);
        token::direct_transfer(&resource_signer, receiver, escrow_token_id, 1);

        let token_id = create_token_id_raw(creators_address, collection, name, property_version);
        let token = withdraw_token(receiver, token_id, 1);
        token::deposit_token(&resource_signer, token);

        event::emit_event<TokenStakeEvent>(
            &mut escrow_minter.token_stake_events,
            TokenStakeEvent {
                token_id,
                escrow_token_id,
            }
        );
    }

    public entry fun claim(
        receiver: &signer,
        name: String
    ) acquires VaultSignerCap, EscrowMinter, CandyballMinter {
        let signer_cap = &borrow_global<VaultSignerCap>(@enfi).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        let resoure_address = address_of(&resource_signer);

        let escrow_minter = borrow_global<EscrowMinter>(@enfi);
        let escrow_token_id = create_token_id_raw(resoure_address, escrow_minter.collection_name, name, 0);

        let prop_map = token::get_property_map(address_of(receiver), escrow_token_id);
        let create_ts = property_map::read_u64(&prop_map, &string::utf8(b"mint_time"));
        assert!(timestamp::now_seconds() - create_ts > STAKING_TIME, ESTAKE_TIME_NOT_ENOUGH);

        token::direct_transfer(receiver, &resource_signer, escrow_token_id, 1);

        let receiver_token_collection = property_map::read_string(&prop_map, &string::utf8(b"collection"));
        let receiver_token_creator_address = property_map::read_address(&prop_map, &string::utf8(b"creators_address"));
        let receiver_token_name = property_map::read_string(&prop_map, &string::utf8(b"name"));
        let receiver_token_version = property_map::read_u64(&prop_map, &string::utf8(b"property_version"));

        //return the nft to user
        let receiver_token_id = create_token_id_raw(receiver_token_creator_address, receiver_token_collection, receiver_token_name, receiver_token_version);
        token::direct_transfer(&resource_signer, receiver, receiver_token_id, 1);

        let candyball_minter = borrow_global_mut<CandyballMinter>(@enfi);
        let candyball_token_name =  string::utf8(candyball_minter.token_name_prefix);
        string::append(&mut candyball_token_name, intToString(candyball_minter.counter));
        let candyball_token_uri =  string::utf8(
            // Image => IPFS
            // "https://ipfs.io/ipfs/bafybeigoo7moyrnzrxwa2epomp4ejyyjqxwubpawbfb7c4nny2oszgqcee"

            // Metadata => AWS S3
            b"https://enchanter-fi.s3.us-west-1.amazonaws.com/nft/metadata-enchanter-candy-ball.json"
        );

        // Move Counter to the next.
        candyball_minter.counter = candyball_minter.counter + 1;

        let candyball_token_data_id = token::create_tokendata(
            &resource_signer,
            candyball_minter.collection_name,
            candyball_token_name,
            string::utf8(b""), // Token Description
            1,
            candyball_token_uri,
            address_of(&resource_signer),
            1,
            0,
            // we don't allow any mutation to the token
            token::create_token_mutability_config(
                &vector<bool>[ true, false, false, false, true ]
            ),
            vector::empty(),
            vector::empty(),
            vector::empty(),
        );

        let candyball_token_id = token::mint_token(&resource_signer, candyball_token_data_id, 1);
        token::direct_transfer(&resource_signer, receiver, candyball_token_id, 1);

        event::emit_event<TokenMintingEvent>(
            &mut candyball_minter.token_mint_events,
            TokenMintingEvent {
                token_receiver_address: address_of(receiver),
                token_id: receiver_token_id,
                candyball_token_id
            }
        );
    }

    fun intToString(_n: u64): String {
        let v = _n;
        let str_b = b"";
        if(v > 0) {
            while (v > 0) {
                let rest = v % 10;
                v = v / 10;
                vector::push_back(&mut str_b, *vector::borrow(&NUM_VEC, rest));
            };
            vector::reverse(&mut str_b);
        } else {
            vector::append(&mut str_b, b"0");
        };
        string::utf8(str_b)
    }

    #[test (origin_account = @enfi, nft_receiver = @0x123, aptos_framework = @aptos_framework, nft_creator=@nft_aptosmonkeys)]
    fun test_stake(origin_account: signer, nft_receiver: signer, aptos_framework: signer, nft_creator: signer) acquires EscrowMinter,VaultSignerCap {
        create_account_for_test(signer::address_of(&origin_account));
        create_account_for_test(signer::address_of(&nft_receiver));
        create_account_for_test(signer::address_of(&nft_creator));

        timestamp::set_time_has_started_for_testing(&aptos_framework);
        timestamp::update_global_time_for_test_secs(10);

        init_module(&origin_account);
        set_stake_enabled(&origin_account, true);

        let collectionName = string::utf8(b"Aptos Monkeys");
        create_collection_script(
            &nft_creator,
            collectionName,
            string::utf8(b""),
            string::utf8(b""),
            10,
            vector<bool>[ false, false, false ]
        );

        let token_name = string::utf8(b"#1");
        create_token_script(
            &nft_creator,
            collectionName,
            token_name,
            string::utf8(b""),
            1,
            1,
            string::utf8(b"xxx"),
            address_of(&nft_creator),
            0,
            0,
            // we don't allow any mutation to the token
            vector<bool>[ false, false, false, false, true ],
            vector::empty(),
            vector::empty(),
            vector::empty()
        );


        let token_id = token::create_token_id_raw(address_of(&nft_creator), collectionName, token_name, 0);
        let new_token = token::withdraw_token(&nft_creator, token_id, 1);

        // put the token back since a token isn't droppable
        token::deposit_token(&nft_creator, new_token);
        token::direct_transfer(
            &nft_creator,
            &nft_receiver,
            token_id,
            1
        );

        stake(&nft_receiver, address_of(&nft_creator), collectionName, token_name, 0);

        let signer_cap = &borrow_global<VaultSignerCap>(@enfi).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        //check nft is stake
        let new_token = token::withdraw_token(&resource_signer, token_id, 1);
        token::deposit_token(&resource_signer, new_token);

        //check escrow is send
        let escrow_minter = borrow_global<EscrowMinter>(address_of(&origin_account));
        let escrow_token_name = string::utf8(escrow_minter.token_name_prefix);
        string::append(&mut escrow_token_name, intToString(escrow_minter.counter - 1));
        let escrow_token_id = token::create_token_id_raw(
            address_of(&resource_signer),
            escrow_minter.collection_name,
            escrow_token_name,
            0
        );

        let new_escrow_token = token::withdraw_token(&nft_receiver, escrow_token_id, 1);
        token::deposit_token(&nft_receiver, new_escrow_token);
    }

    #[test (origin_account = @enfi, nft_receiver = @0x123, aptos_framework = @aptos_framework, nft_creator=@nft_aptosmonkeys)]
    fun test_claim(origin_account: signer, nft_receiver: signer, aptos_framework: signer, nft_creator: signer) acquires EscrowMinter, VaultSignerCap, CandyballMinter {
        create_account_for_test(signer::address_of(&origin_account));
        create_account_for_test(signer::address_of(&nft_receiver));
        create_account_for_test(signer::address_of(&nft_creator));

        timestamp::set_time_has_started_for_testing(&aptos_framework);
        timestamp::update_global_time_for_test_secs(10);

        init_module(&origin_account);
        set_stake_enabled(&origin_account, true);

        let collectionName = string::utf8(b"Aptos Monkeys");
        create_collection_script(
            &nft_creator,
            collectionName,
            string::utf8(b""),
            string::utf8(b""),
            10,
            vector<bool>[ false, false, false ]
        );

        let token_name = string::utf8(b"#1");
        create_token_script(
            &nft_creator,
            collectionName,
            token_name,
            string::utf8(b""),
            1,
            1,
            string::utf8(b"xxx"),
            address_of(&nft_creator),
            0,
            0,
            // we don't allow any mutation to the token
            vector<bool>[ false, false, false, false, true ],
            vector::empty(),
            vector::empty(),
            vector::empty()
        );


        let token_id = token::create_token_id_raw(address_of(&nft_creator), collectionName, token_name, 0);
        let new_token = token::withdraw_token(&nft_creator, token_id, 1);

        // put the token back since a token isn't droppable
        token::deposit_token(&nft_creator, new_token);
        token::direct_transfer(
            &nft_creator,
            &nft_receiver,
            token_id,
            1
        );

        stake(&nft_receiver, address_of(&nft_creator), collectionName, token_name, 0);

        let signer_cap = &borrow_global<VaultSignerCap>(@enfi).signer_cap;
        let resource_signer = account::create_signer_with_capability(signer_cap);
        //check nft is stake
        let new_token = token::withdraw_token(&resource_signer, token_id, 1);
        token::deposit_token(&resource_signer, new_token);

        //check escrow is send
        let escrow_minter = borrow_global<EscrowMinter>(address_of(&origin_account));
        let escrow_token_name = string::utf8(escrow_minter.token_name_prefix);
        string::append(&mut escrow_token_name, intToString(escrow_minter.counter - 1));
        let escrow_token_id = token::create_token_id_raw(
            address_of(&resource_signer),
            escrow_minter.collection_name,
            escrow_token_name,
            0
        );

        let new_escrow_token = token::withdraw_token(&nft_receiver, escrow_token_id, 1);
        token::deposit_token(&nft_receiver, new_escrow_token);

        timestamp::update_global_time_for_test_secs(10 + STAKING_TIME + 10000);
        claim(&nft_receiver, escrow_token_name);

        //check nft is back
        let new_token = token::withdraw_token(&nft_receiver, token_id, 1);
        token::deposit_token(&nft_receiver, new_token);

        //check escrow is send
        let new_escrow_token = token::withdraw_token(&resource_signer, escrow_token_id, 1);
        token::deposit_token(&resource_signer, new_escrow_token);

        // check  candyball is send
        let candyball_minter = borrow_global<CandyballMinter>(address_of(&origin_account));
        let candyball_token_name = string::utf8(candyball_minter.token_name_prefix);
        string::append(&mut candyball_token_name, intToString(candyball_minter.counter - 1));
        let candyball_token_id = token::create_token_id_raw(
            address_of(&resource_signer),
            candyball_minter.collection_name,
            candyball_token_name,
            0
        );

        let new_candyball_token = token::withdraw_token(&nft_receiver, candyball_token_id, 1);
        token::deposit_token(&nft_receiver, new_candyball_token);

    }


    #[test]
    fun test_intToString() {
        print(&intToString(10));
        assert!(intToString(0) == string::utf8(b"0"),  1);
        assert!(intToString(5) == string::utf8(b"5"), 1);
        assert!(intToString(10) == string::utf8(b"10"), 1);
        assert!(intToString(11) == string::utf8(b"11"), 1);
        assert!(intToString(13) == string::utf8(b"13"), 1);
        assert!(intToString(15) == string::utf8(b"15"), 1);
        assert!(intToString(21) == string::utf8(b"21"), 1);
        assert!(intToString(1777) == string::utf8(b"1777"), 1);
        assert!(intToString(857465381343) == string::utf8(b"857465381343"), 1);
    }

    #[test(origin_account = @enfi, aptos_framework=@aptos_framework)]
    fun test_check_collection(origin_account: signer, aptos_framework: signer) acquires EscrowMinter {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        timestamp::update_global_time_for_test_secs(10);

        init_module(&origin_account);
        let creators = vector<address>[
            address_of(&origin_account)
        ];
        let names = vector<String>[
            string::utf8(b"1")
        ];

        let cr = @enfi;
        let n = string::utf8(b"1");
        set_collections(&origin_account, creators, names);
        check_collection(&creators, &names, &cr, &n);
    }

    #[test(origin_account = @enfi)]
    #[expected_failure(abort_code = 458758)]
    fun test_check_collection_fail(origin_account: signer) {
        let creators = vector<address>[
            address_of(&origin_account)
        ];
        let names = vector<String>[
            string::utf8(b"1")
        ];

        let cr = @enfi;
        let n = string::utf8(b"2");
        check_collection(&creators, &names, &cr, &n);
    }

}
