// Copyright (c) 2026 Stefano Della Valle
// SPDX-License-Identifier: LicenseRef-Proprietary

module iota_oracle_system_state::systemState {
    use iota_system::iota_system::IotaSystemState;
    use iota::coin::{Self as coin, Coin};
    use iota::dynamic_field;
    use iota::clock::Clock;
    use iota::event;
    use iota::iota::IOTA;
    use iota_oracle_validator_caps::validator_caps;
    use iota_oracle_validator_caps::validator_caps::DelegatedControllerCap;

    const ENotInCommittee: u64 = 1;
    const ENotFound: u64 = 3;
    const EOracleAddrTaken: u64 = 4;
    const EOracleSenderMismatch: u64 = 8;
    const EFeeBpsTooHigh: u64 = 6;
    const EInvalidNetworkMode: u64 = 7;

    const ETemplateNotFound: u64 = 41;
    const ETemplateDisabled: u64 = 42;
    const EInputTooLarge: u64 = 43;
    const EInvalidRetentionDays: u64 = 44;
    const EDownloadTooLarge: u64 = 45;
    const EInvalidRequestedNodes: u64 = 46;

    const EAlreadyApproved: u64 = 63;
    const ENoOracleNodesRegistered: u64 = 64;
    const EInvalidProposalKind: u64 = 66;
    const EProposalNotFound: u64 = 67;
    const EValidatorCapAlreadyRegistered: u64 = 68;
    const EDelegatedCapInUse: u64 = 69;
    const EWrongNodeRegistry: u64 = 70;
    const EUnprunedEpoch: u64 = 18446744073709551615;

    const PROPOSAL_KIND_NONE: u8 = 0;
    const PROPOSAL_KIND_TEMPLATE_UPSERT: u8 = 1;
    const PROPOSAL_KIND_TEMPLATE_REMOVE: u8 = 2;

    public struct OracleNode has copy, drop, store {
        node_id: u64,
        validator: address,
        addr: address,
        pubkey: vector<u8>,
        accepted_template_ids: vector<u64>,
        delegated_controller_cap_id: object::ID,
        validator_controller_cap_id: object::ID,
    }

    public struct OracleTreasuryBalanceKey has copy, drop, store {}

    public struct TaskTemplateKey has copy, drop, store {
        template_id: u64,
    }

    public struct TemplateProposalApprovalKey has copy, drop, store {
        proposal_id: u64,
        voter: address,
    }

    // Price governed by oracle nodes:
    // per_node_raw_payment = base_price_iota + download_price + retention_days * price_per_retention_day_iota
    // raw_payment = requested_nodes * per_node_raw_payment
    // required_payment = max(min_payment, raw_payment + system_fee(raw_payment))
    // for non-storage templates, allow_storage=0 and retention_days must be 0
    public struct TaskTemplate has copy, drop, store {
        template_id: u64,
        task_type: vector<u8>,
        is_enabled: u8,

        base_price_iota: u64,
        scheduler_fee_iota: u64,

        max_input_bytes: u64,
        max_output_bytes: u64,
        included_download_bytes: u64,
        price_per_download_byte_iota: u64,

        allow_storage: u8,
        min_retention_days: u64,
        max_retention_days: u64,
        price_per_retention_day_iota: u64,
    }

    public struct TaskTemplateProposal has copy, drop, store {
        proposal_id: u64,
        proposal_kind: u8,
        approvals: u64,
        electorate_size: u64,

        template_id: u64,
        task_type: vector<u8>,
        is_enabled: u8,
        base_price_iota: u64,
        scheduler_fee_iota: u64,
        max_input_bytes: u64,
        max_output_bytes: u64,
        included_download_bytes: u64,
        price_per_download_byte_iota: u64,
        allow_storage: u8,
        min_retention_days: u64,
        max_retention_days: u64,
        price_per_retention_day_iota: u64,
    }

    public struct NodeRegistry has key, store {
        id: object::UID,
        oracle_nodes: vector<OracleNode>,
        next_oracle_node_id: u64,
        last_committee_prune_epoch: u64,
    }

    // Renamed from Status -> State
    public struct State has key, store {
        id: object::UID,
        network: vector<u8>,
        node_registry_id: object::ID,

        // config economica globale minima
        system_fee_bps: u64,
        min_payment: u64,

        // proposals
        template_proposal_id: u64,
        template_proposals: vector<TaskTemplateProposal>,
    }

    // Oggetto separato che riceve i fondi dei task
    public struct OracleTreasury has key, store {
        id: object::UID,
    }

    public struct ControllerCap has key, store { id: object::UID }

    public struct TaskTemplateProposalCreated has copy, drop {
        proposal_id: u64,
        proposal_kind: u8,
        template_id: u64,
        proposer: address,
        electorate_size: u64,
        approvals_needed: u64,
    }

    public struct TaskTemplateProposalApproved has copy, drop {
        proposal_id: u64,
        proposal_kind: u8,
        template_id: u64,
        by: address,
        approvals: u64,
        approvals_needed: u64,
    }

    public struct TaskTemplateProposalApplied has copy, drop {
        proposal_id: u64,
        proposal_kind: u8,
        template_id: u64,
        approvals: u64,
        approvals_needed: u64,
    }

    public struct TaskTemplateUpserted has copy, drop {
        template_id: u64,
        is_enabled: u8,
    }

    public struct TaskTemplateRemoved has copy, drop {
        template_id: u64,
    }

    public struct OracleTreasuryDeposited has copy, drop {
        from: address,
        amount: u64,
    }

    public struct OracleTreasuryWithdrawn has copy, drop {
        to: address,
        amount: u64,
    }

    fun init(ctx: &mut TxContext) {
        let sender = iota::tx_context::sender(ctx);

        let node_registry = NodeRegistry {
            id: object::new(ctx),
            oracle_nodes: vector::empty(),
            next_oracle_node_id: 1,
            last_committee_prune_epoch: EUnprunedEpoch,
        };
        let node_registry_id = object::id(&node_registry);

        let mut st = State {
            id: object::new(ctx),
            network: b"testnet",
            node_registry_id,

            system_fee_bps: 500,
            min_payment: 0,

            template_proposal_id: 0,
            template_proposals: vector::empty(),
        };
        bootstrap_approved_templates(&mut st);
        transfer::share_object(st);
        transfer::share_object(node_registry);

        let treasury = OracleTreasury { id: object::new(ctx) };
        transfer::share_object(treasury);

        let cap = ControllerCap { id: object::new(ctx) };
        transfer::transfer(cap, sender);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

    // BEGIN APPROVED TEMPLATE SNAPSHOT
    // Frozen approved configuration; executed only by module init.
    fun bootstrap_approved_templates(st: &mut State) {
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 4 }, TaskTemplate {
            allow_storage: 1,
            base_price_iota: 1000000000,
            included_download_bytes: 10485760,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 10485760,
            max_retention_days: 30,
            min_retention_days: 30,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 347034,
            scheduler_fee_iota: 21323200,
            task_type: vector[83, 84, 79, 82, 65, 71, 69],
            template_id: 4,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 5 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 21323200,
            task_type: vector[76, 76, 77, 95, 69, 88, 84, 82, 65, 67, 84, 95, 83, 84, 82, 85, 67, 84, 85, 82, 69, 68],
            template_id: 5,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 6 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 21323200,
            task_type: vector[76, 76, 77, 95, 67, 76, 65, 83, 83, 73, 70, 89, 95, 68, 79, 67, 85, 77, 69, 78, 84],
            template_id: 6,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 7 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 21323200,
            task_type: vector[76, 76, 77, 95, 82, 73, 83, 75, 95, 83, 67, 79, 82, 69],
            template_id: 7,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 8 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 21323200,
            task_type: vector[68, 76, 86, 67, 95, 86, 65, 76, 73, 68, 65, 84, 73, 79, 78],
            template_id: 8,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 9 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 21323200,
            task_type: vector[71, 69, 84, 95, 84, 69, 88, 84, 95, 83, 84, 82, 73, 80],
            template_id: 9,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 10 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 21323200,
            task_type: vector[71, 69, 84, 95, 74, 83, 79, 78, 95, 67, 65, 78, 79, 78, 73, 67, 65, 76],
            template_id: 10,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 11 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 21323200,
            task_type: vector[71, 69, 84, 95, 72, 84, 77, 76, 95, 83, 84, 82, 73, 80, 95, 68, 89, 78, 65, 77, 73, 67],
            template_id: 11,
        });
        dynamic_field::add(&mut st.id, TaskTemplateKey { template_id: 12 }, TaskTemplate {
            allow_storage: 0,
            base_price_iota: 1000000000,
            included_download_bytes: 8192,
            is_enabled: 1,
            max_input_bytes: 8192,
            max_output_bytes: 8192,
            max_retention_days: 0,
            min_retention_days: 0,
            price_per_download_byte_iota: 0,
            price_per_retention_day_iota: 0,
            scheduler_fee_iota: 0,
            task_type: vector[76, 76, 77, 95, 79, 80, 69, 78, 95, 81, 85, 69, 83, 84, 73, 79, 78],
            template_id: 12,
        });
    }
    // END APPROVED TEMPLATE SNAPSHOT

    public entry fun set_global_economic_config(
        _cap: &ControllerCap,
        st: &mut State,
        system_fee_bps: u64,
        min_payment: u64,
        _ctx: &mut TxContext
    ) {
        assert!(system_fee_bps <= 10_000, EFeeBpsTooHigh);
        st.system_fee_bps = system_fee_bps;
        st.min_payment = min_payment;
    }

    public entry fun delete_delegated_controller_cap(
        node_registry: &NodeRegistry,
        delegated_cap: DelegatedControllerCap
    ) {
        let delegated_cap_id = object::id(&delegated_cap);
        assert!(
            !has_registered_delegated_cap(node_registry, delegated_cap_id),
            EDelegatedCapInUse
        );
        validator_caps::delete_delegated_controller_cap(delegated_cap);
    }

    // =========================================================
    // TEMPLATE PRICING GOVERNANCE
    // =========================================================

    public entry fun propose_task_template_upsert(
        _cap: &ControllerCap,
        node_registry: &NodeRegistry,
        st: &mut State,
        _clock: &Clock,
        _proposal_timeout_ms: u64,
        template_id: u64,
        task_type: vector<u8>,
        is_enabled: u8,
        base_price_iota: u64,
        scheduler_fee_iota: u64,
        max_input_bytes: u64,
        max_output_bytes: u64,
        included_download_bytes: u64,
        price_per_download_byte_iota: u64,
        allow_storage: u8,
        min_retention_days: u64,
        max_retention_days: u64,
        price_per_retention_day_iota: u64,
        ctx: &mut TxContext
    ) {
        let electorate = vector::length(&node_registry.oracle_nodes);
        assert!(electorate > 0, ENoOracleNodesRegistered);

        let pid = st.template_proposal_id + 1;
        st.template_proposal_id = pid;
        vector::push_back(&mut st.template_proposals, TaskTemplateProposal {
            proposal_id: pid,
            proposal_kind: PROPOSAL_KIND_TEMPLATE_UPSERT,
            approvals: 0,
            electorate_size: electorate,
            template_id,
            task_type,
            is_enabled,
            base_price_iota,
            scheduler_fee_iota,
            max_input_bytes,
            max_output_bytes,
            included_download_bytes,
            price_per_download_byte_iota,
            allow_storage,
            min_retention_days,
            max_retention_days,
            price_per_retention_day_iota,
        });

        let proposer = iota::tx_context::sender(ctx);
        event::emit(TaskTemplateProposalCreated {
            proposal_id: pid,
            proposal_kind: PROPOSAL_KIND_TEMPLATE_UPSERT,
            template_id,
            proposer,
            electorate_size: electorate,
            approvals_needed: majority_threshold(electorate),
        });
    }

    public entry fun propose_task_template_remove(
        _cap: &ControllerCap,
        node_registry: &NodeRegistry,
        st: &mut State,
        _clock: &Clock,
        _proposal_timeout_ms: u64,
        template_id: u64,
        ctx: &mut TxContext
    ) {
        let electorate = vector::length(&node_registry.oracle_nodes);
        assert!(electorate > 0, ENoOracleNodesRegistered);

        let pid = st.template_proposal_id + 1;
        st.template_proposal_id = pid;
        vector::push_back(&mut st.template_proposals, TaskTemplateProposal {
            proposal_id: pid,
            proposal_kind: PROPOSAL_KIND_TEMPLATE_REMOVE,
            approvals: 0,
            electorate_size: electorate,
            template_id,
            task_type: vector::empty(),
            is_enabled: 0,
            base_price_iota: 0,
            scheduler_fee_iota: 0,
            max_input_bytes: 0,
            max_output_bytes: 0,
            included_download_bytes: 0,
            price_per_download_byte_iota: 0,
            allow_storage: 0,
            min_retention_days: 0,
            max_retention_days: 0,
            price_per_retention_day_iota: 0,
        });

        let proposer = iota::tx_context::sender(ctx);
        event::emit(TaskTemplateProposalCreated {
            proposal_id: pid,
            proposal_kind: PROPOSAL_KIND_TEMPLATE_REMOVE,
            template_id,
            proposer,
            electorate_size: electorate,
            approvals_needed: majority_threshold(electorate),
        });
    }

    public entry fun approve_task_template_proposal(
        node_registry: &NodeRegistry,
        st: &mut State,
        _clock: &Clock,
        proposal_id: u64,
        ctx: &mut TxContext
    ) {
        let sender = iota::tx_context::sender(ctx);
        assert!(has_node_ref(node_registry, sender), ENotFound);

        let idx = find_proposal_index(st, proposal_id);
        assert!(idx < vector::length(&st.template_proposals), EProposalNotFound);

        let key = TemplateProposalApprovalKey {
            proposal_id,
            voter: sender,
        };
        assert!(
            !dynamic_field::exists_<TemplateProposalApprovalKey>(&st.id, key),
            EAlreadyApproved
        );

        dynamic_field::add<TemplateProposalApprovalKey, bool>(&mut st.id, key, true);
        let (proposal_kind, template_id, approvals, needed, upsert_enabled) = {
            let p = vector::borrow_mut(&mut st.template_proposals, idx);
            assert!(
                p.proposal_kind == PROPOSAL_KIND_TEMPLATE_UPSERT ||
                p.proposal_kind == PROPOSAL_KIND_TEMPLATE_REMOVE,
                EInvalidProposalKind
            );
            p.approvals = p.approvals + 1;
            (
                p.proposal_kind,
                p.template_id,
                p.approvals,
                majority_threshold(p.electorate_size),
                p.is_enabled,
            )
        };

        event::emit(TaskTemplateProposalApproved {
            proposal_id,
            proposal_kind,
            template_id,
            by: sender,
            approvals,
            approvals_needed: needed,
        });

        if (approvals >= needed) {
            if (proposal_kind == PROPOSAL_KIND_TEMPLATE_UPSERT) {
                apply_template_upsert(st, idx);
                event::emit(TaskTemplateUpserted {
                    template_id,
                    is_enabled: upsert_enabled,
                });
            } else {
                apply_template_remove(st, idx);
                event::emit(TaskTemplateRemoved {
                    template_id,
                });
            };

            event::emit(TaskTemplateProposalApplied {
                proposal_id,
                proposal_kind,
                template_id,
                approvals,
                approvals_needed: needed,
            });

            remove_proposal_at(st, idx);
        };
    }

    // =========================================================
    // TEMPLATE GETTERS + VALIDATION
    // =========================================================

    public fun has_task_template(st: &State, template_id: u64): bool {
        let key = TaskTemplateKey { template_id };
        dynamic_field::exists_<TaskTemplateKey>(&st.id, key)
    }

    public fun borrow_task_template(st: &State, template_id: u64): &TaskTemplate {
        let key = TaskTemplateKey { template_id };
        assert!(dynamic_field::exists_<TaskTemplateKey>(&st.id, key), ETemplateNotFound);
        dynamic_field::borrow<TaskTemplateKey, TaskTemplate>(&st.id, key)
    }

    public fun task_template_is_enabled(st: &State, template_id: u64): u8 {
        let tpl = borrow_task_template(st, template_id);
        tpl.is_enabled
    }

    public fun task_template_task_type(st: &State, template_id: u64): vector<u8> {
        let tpl = borrow_task_template(st, template_id);
        copy_bytes(&tpl.task_type)
    }

    public fun task_template_base_price_iota(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.base_price_iota
    }

    public fun task_template_scheduler_fee_iota(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.scheduler_fee_iota
    }

    public fun task_template_max_input_bytes(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.max_input_bytes
    }

    public fun task_template_max_output_bytes(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.max_output_bytes
    }

    public fun task_template_included_download_bytes(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.included_download_bytes
    }

    public fun task_template_price_per_download_byte_iota(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.price_per_download_byte_iota
    }

    public fun task_template_allow_storage(st: &State, template_id: u64): u8 {
        let tpl = borrow_task_template(st, template_id);
        tpl.allow_storage
    }

    public fun task_template_min_retention_days(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.min_retention_days
    }

    public fun task_template_max_retention_days(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.max_retention_days
    }

    public fun task_template_price_per_retention_day_iota(st: &State, template_id: u64): u64 {
        let tpl = borrow_task_template(st, template_id);
        tpl.price_per_retention_day_iota
    }

    public fun validate_task_request_and_get_payment_split(
        st: &State,
        template_id: u64,
        requested_nodes: u64,
        payload_bytes_len: u64,
        retention_days: u64,
        declared_download_bytes: u64
    ): (u64, u64, u64) {
        assert!(has_task_template(st, template_id), ETemplateNotFound);
        assert!(task_template_is_enabled(st, template_id) == 1, ETemplateDisabled);
        assert!(requested_nodes > 0, EInvalidRequestedNodes);
        assert!(payload_bytes_len <= task_template_max_input_bytes(st, template_id), EInputTooLarge);
        assert!(declared_download_bytes <= task_template_max_output_bytes(st, template_id), EDownloadTooLarge);

        let allow_storage = task_template_allow_storage(st, template_id);
        if (allow_storage == 0) {
            assert!(retention_days == 0, EInvalidRetentionDays);
        } else {
            let min_days = task_template_min_retention_days(st, template_id);
            let max_days = task_template_max_retention_days(st, template_id);
            assert!(retention_days >= min_days, EInvalidRetentionDays);
            assert!(retention_days <= max_days, EInvalidRetentionDays);
        };

        let included_download_bytes = task_template_included_download_bytes(st, template_id);
        let extra_download_bytes = saturating_sub_u64(declared_download_bytes, included_download_bytes);
        let download_price =
            extra_download_bytes * task_template_price_per_download_byte_iota(st, template_id);

        let per_node_raw =
            task_template_base_price_iota(st, template_id) +
            download_price +
            retention_days * task_template_price_per_retention_day_iota(st, template_id);
        let raw = per_node_raw * requested_nodes;
        let system_fee = fee_amount_from_bps(raw, st.system_fee_bps);
        let total = raw + system_fee;
        let required = max_u64(total, st.min_payment);
        (raw, system_fee, required)
    }

    public fun validate_task_request_and_get_payment(
        st: &State,
        template_id: u64,
        requested_nodes: u64,
        payload_bytes_len: u64,
        retention_days: u64,
        declared_download_bytes: u64
    ): u64 {
        let (_, _, required) = validate_task_request_and_get_payment_split(
            st,
            template_id,
            requested_nodes,
            payload_bytes_len,
            retention_days,
            declared_download_bytes
        );
        required
    }

    // =========================================================
    // ORACLE NODES
    // =========================================================

    public entry fun register_oracle_node(
        node_registry: &mut NodeRegistry,
        st: &State,
        system: &mut IotaSystemState,
        delegated_cap: &DelegatedControllerCap,
        oracle_addr: address,
        pubkey: vector<u8>,
        accepted_template_ids: vector<u64>,
        ctx: &mut TxContext
    ) {
        // Only this capability-checked path may populate the testnet registry.
        assert!(!is_devnet(st), EInvalidNetworkMode);
        assert!(object::id(node_registry) == st.node_registry_id, EWrongNodeRegistry);
        prune_oracle_nodes_if_epoch_changed(node_registry, st, system, ctx);
        let sender = iota::tx_context::sender(ctx);
        assert!(sender == oracle_addr, EOracleSenderMismatch);
        let validator = validator_address_from_delegated_cap(system, delegated_cap);
        let delegated_cap_id = object::id(delegated_cap);
        let validator_cap_id = validator_cap_id_from_delegated_cap(delegated_cap);
        upsert_oracle_node(
            node_registry,
            validator,
            oracle_addr,
            pubkey,
            accepted_template_ids,
            delegated_cap_id,
            validator_cap_id,
        );
    }

    public entry fun register_oracle_node_dev(
        _node_registry: &mut NodeRegistry,
        _oracle_addr: address,
        _pubkey: vector<u8>,
        _accepted_template_ids: vector<u64>,
        _ctx: &mut TxContext
    ) {
        // Retain the ABI only to reject old clients explicitly. A network
        // setting supplied by a client must never enable cap-free registration.
        abort EInvalidNetworkMode
    }
    

    public entry fun unregister_oracle_node(node_registry: &mut NodeRegistry, ctx: &mut TxContext) {
        let sender = iota::tx_context::sender(ctx);
        let removed = remove_node(node_registry, sender);
        assert!(removed, ENotFound);
    }

    public entry fun unregister_oracle_node_dev(node_registry: &mut NodeRegistry, ctx: &mut TxContext) {
        unregister_oracle_node(node_registry, ctx);
    }

    public fun node_registry_id(st: &State): object::ID { st.node_registry_id }
    public fun oracle_nodes(node_registry: &NodeRegistry): &vector<OracleNode> { &node_registry.oracle_nodes }
    public fun last_committee_prune_epoch(node_registry: &NodeRegistry): u64 { node_registry.last_committee_prune_epoch }
    public fun oracle_node_id(n: &OracleNode): u64 { n.node_id }
    public fun oracle_node_addr(n: &OracleNode): address { n.addr }
    public fun oracle_node_accepts_template(n: &OracleNode, template_id: u64): bool {
        contains_u64(&n.accepted_template_ids, template_id)
    }
    public fun oracle_node_accepted_templates(n: &OracleNode): &vector<u64> { &n.accepted_template_ids }
    public fun oracle_node_delegated_controller_cap_id(n: &OracleNode): object::ID { n.delegated_controller_cap_id }
    public fun oracle_node_validator_controller_cap_id(n: &OracleNode): object::ID { n.validator_controller_cap_id }
    // Backward compatibility for older readers expecting `payload`.
    public fun payload(st: &State): &vector<u8> { &st.network }
    public fun network(st: &State): &vector<u8> { &st.network }

    public fun system_fee_bps(st: &State): u64 { st.system_fee_bps }
    public fun min_payment(st: &State): u64 { st.min_payment }

    public fun template_proposal_active(st: &State): u8 { if (vector::length(&st.template_proposals) > 0) 1 else 0 }
    public fun template_proposal_id(st: &State): u64 { st.template_proposal_id }
    public fun template_proposal_kind(st: &State): u8 {
        if (vector::length(&st.template_proposals) == 0) PROPOSAL_KIND_NONE else vector::borrow(&st.template_proposals, 0).proposal_kind
    }
    public fun template_proposal_approvals(st: &State): u64 {
        if (vector::length(&st.template_proposals) == 0) 0 else vector::borrow(&st.template_proposals, 0).approvals
    }
    public fun template_proposal_electorate_size(st: &State): u64 {
        if (vector::length(&st.template_proposals) == 0) 0 else vector::borrow(&st.template_proposals, 0).electorate_size
    }
    public fun proposed_template_id(st: &State): u64 {
        if (vector::length(&st.template_proposals) == 0) 0 else vector::borrow(&st.template_proposals, 0).template_id
    }

    // =========================================================
    // TREASURY
    // =========================================================

    public fun deposit_treasury_iota(treasury: &mut OracleTreasury, fee: Coin<IOTA>, from: address) {
        let amount = coin::value(&fee);
        let key = OracleTreasuryBalanceKey {};
        if (dynamic_field::exists_<OracleTreasuryBalanceKey>(&treasury.id, key)) {
            let bal: &mut Coin<IOTA> =
                dynamic_field::borrow_mut<OracleTreasuryBalanceKey, Coin<IOTA>>(&mut treasury.id, key);
            coin::join(bal, fee);
        } else {
            dynamic_field::add<OracleTreasuryBalanceKey, Coin<IOTA>>(&mut treasury.id, key, fee);
        };
        event::emit(OracleTreasuryDeposited { from, amount });
    }

    public entry fun withdraw_treasury_iota(
        _cap: &ControllerCap,
        treasury: &mut OracleTreasury,
        amount: u64,
        to: address,
        ctx: &mut TxContext
    ) {
        let key = OracleTreasuryBalanceKey {};
        let bal: &mut Coin<IOTA> =
            dynamic_field::borrow_mut<OracleTreasuryBalanceKey, Coin<IOTA>>(&mut treasury.id, key);
        let out = coin::split(bal, amount, ctx);
        transfer::public_transfer(out, to);
        event::emit(OracleTreasuryWithdrawn { to, amount });
    }

    public fun treasury_balance_iota(treasury: &OracleTreasury): u64 {
        let key = OracleTreasuryBalanceKey {};
        if (dynamic_field::exists_<OracleTreasuryBalanceKey>(&treasury.id, key)) {
            let bal: &Coin<IOTA> =
                dynamic_field::borrow<OracleTreasuryBalanceKey, Coin<IOTA>>(&treasury.id, key);
            coin::value(bal)
        } else {
            0
        }
    }

    fun fee_amount_from_bps(amount: u64, bps: u64): u64 {
        if (amount == 0 || bps == 0) {
            0
        } else {
            (amount * bps + 9_999) / 10_000
        }
    }

    // =========================================================
    // INTERNALS
    // =========================================================

    fun apply_template_upsert(st: &mut State, proposal_idx: u64) {
        let p = vector::borrow(&st.template_proposals, proposal_idx);
        let key = TaskTemplateKey { template_id: p.template_id };
        let tpl = TaskTemplate {
            template_id: p.template_id,
            task_type: copy_bytes(&p.task_type),
            is_enabled: p.is_enabled,
            base_price_iota: p.base_price_iota,
            scheduler_fee_iota: p.scheduler_fee_iota,
            max_input_bytes: p.max_input_bytes,
            max_output_bytes: p.max_output_bytes,
            included_download_bytes: p.included_download_bytes,
            price_per_download_byte_iota: p.price_per_download_byte_iota,
            allow_storage: p.allow_storage,
            min_retention_days: p.min_retention_days,
            max_retention_days: p.max_retention_days,
            price_per_retention_day_iota: p.price_per_retention_day_iota,
        };

        if (dynamic_field::exists_<TaskTemplateKey>(&st.id, key)) {
            let _old: TaskTemplate =
                dynamic_field::remove<TaskTemplateKey, TaskTemplate>(&mut st.id, key);
        };
        dynamic_field::add<TaskTemplateKey, TaskTemplate>(&mut st.id, key, tpl);
    }

    fun apply_template_remove(st: &mut State, proposal_idx: u64) {
        let p = vector::borrow(&st.template_proposals, proposal_idx);
        let key = TaskTemplateKey { template_id: p.template_id };
        assert!(dynamic_field::exists_<TaskTemplateKey>(&st.id, key), ETemplateNotFound);
        let _old: TaskTemplate =
            dynamic_field::remove<TaskTemplateKey, TaskTemplate>(&mut st.id, key);
    }

    fun remove_proposal_at(st: &mut State, idx: u64) {
        let last = vector::length(&st.template_proposals);
        if (last == 0) return;
        let last_idx = last - 1;
        if (idx != last_idx) {
            let tmp = *vector::borrow(&st.template_proposals, last_idx);
            *vector::borrow_mut(&mut st.template_proposals, idx) = tmp;
        };
        vector::pop_back(&mut st.template_proposals);
    }

    fun find_proposal_index(st: &State, proposal_id: u64): u64 {
        let mut i = 0;
        while (i < vector::length(&st.template_proposals)) {
            let p = vector::borrow(&st.template_proposals, i);
            if (p.proposal_id == proposal_id) return i;
            i = i + 1;
        };
        vector::length(&st.template_proposals)
    }

    fun majority_threshold(n: u64): u64 {
        (n / 2) + 1
    }

    public fun prune_oracle_nodes_if_epoch_changed(
        node_registry: &mut NodeRegistry,
        st: &State,
        system: &mut IotaSystemState,
        ctx: &TxContext,
    ) {
        if (is_devnet(st)) return;

        let current_epoch = ctx.epoch();
        if (node_registry.last_committee_prune_epoch == current_epoch) return;

        let committee = iota_system::iota_system::committee_validator_addresses(system);
        prune_non_committee_oracle_nodes(node_registry, &committee);
        node_registry.last_committee_prune_epoch = current_epoch;
    }

    fun has_node_ref(node_registry: &NodeRegistry, a: address): bool {
        let mut i = 0;
        while (i < vector::length(&node_registry.oracle_nodes)) {
            let n = vector::borrow(&node_registry.oracle_nodes, i);
            if (n.addr == a) return true;
            i = i + 1;
        };
        false
    }

    fun upsert_oracle_node(
        node_registry: &mut NodeRegistry,
        validator: address,
        oracle_addr: address,
        pubkey: vector<u8>,
        accepted_template_ids: vector<u64>,
        delegated_cap_id: object::ID,
        validator_cap_id: object::ID,
    ) {
        let mut i = 0;
        while (i < vector::length(&node_registry.oracle_nodes)) {
            let n = vector::borrow(&node_registry.oracle_nodes, i);

            if (n.addr == oracle_addr && n.validator != validator) abort EOracleAddrTaken;
            if (n.validator_controller_cap_id == validator_cap_id && n.addr != oracle_addr) {
                abort EValidatorCapAlreadyRegistered
            };
            if (n.delegated_controller_cap_id == delegated_cap_id && n.addr != oracle_addr) {
                abort EDelegatedCapInUse
            };

            if (n.validator_controller_cap_id == validator_cap_id) {
                let n_mut = vector::borrow_mut(&mut node_registry.oracle_nodes, i);
                n_mut.validator = validator;
                n_mut.addr = oracle_addr;
                n_mut.pubkey = pubkey;
                n_mut.accepted_template_ids = accepted_template_ids;
                n_mut.delegated_controller_cap_id = delegated_cap_id;
                n_mut.validator_controller_cap_id = validator_cap_id;
                return
            };

            i = i + 1;
        };

        let node_id = node_registry.next_oracle_node_id;
        node_registry.next_oracle_node_id = node_id + 1;
        vector::push_back(&mut node_registry.oracle_nodes, OracleNode {
            node_id,
            validator,
            addr: oracle_addr,
            pubkey,
            accepted_template_ids,
            delegated_controller_cap_id: delegated_cap_id,
            validator_controller_cap_id: validator_cap_id,
        });
    }

    fun prune_non_committee_oracle_nodes(node_registry: &mut NodeRegistry, committee: &vector<address>) {
        let mut i = 0;
        while (i < vector::length(&node_registry.oracle_nodes)) {
            let validator = vector::borrow(&node_registry.oracle_nodes, i).validator;
            if (!contains_addr(committee, validator)) {
                remove_node_at(node_registry, i);
            } else {
                i = i + 1;
            };
        };
    }

    fun remove_node(node_registry: &mut NodeRegistry, a: address): bool {
        let mut i = 0;
        while (i < vector::length(&node_registry.oracle_nodes)) {
            let n = vector::borrow(&node_registry.oracle_nodes, i);
            if (n.addr == a) {
                remove_node_at(node_registry, i);
                return true
            };
            i = i + 1;
        };
        false
    }

    fun remove_node_at(node_registry: &mut NodeRegistry, idx: u64) {
        let last = vector::length(&node_registry.oracle_nodes) - 1;
        if (idx != last) {
            let tmp = *vector::borrow(&node_registry.oracle_nodes, last);
            *vector::borrow_mut(&mut node_registry.oracle_nodes, idx) = tmp;
        };
        vector::pop_back(&mut node_registry.oracle_nodes);
    }

    fun contains_addr(v: &vector<address>, a: address): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == a) return true;
            i = i + 1;
        };
        false
    }

    fun contains_u64(v: &vector<u64>, x: u64): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == x) return true;
            i = i + 1;
        };
        false
    }

    fun copy_bytes(v: &vector<u8>): vector<u8> {
        let mut out = vector::empty<u8>();
        let mut i = 0;
        while (i < vector::length(v)) {
            vector::push_back(&mut out, *vector::borrow(v, i));
            i = i + 1;
        };
        out
    }

    fun max_u64(a: u64, b: u64): u64 {
        if (a >= b) a else b
    }

    fun saturating_sub_u64(a: u64, b: u64): u64 {
        if (a >= b) a - b else 0
    }

    fun validator_cap_id_from_delegated_cap(cap: &DelegatedControllerCap): object::ID {
        validator_caps::validator_cap_id(cap)
    }

    fun validator_address_from_delegated_cap(
        system: &mut IotaSystemState,
        delegated_cap: &DelegatedControllerCap,
    ): address {
        let delegated_validator = validator_caps::validator_address(delegated_cap);
        let committee = iota_system::iota_system::committee_validator_addresses(system);
        if (contains_addr(&committee, delegated_validator)) return delegated_validator;
        abort ENotInCommittee
    }

    fun has_registered_delegated_cap(node_registry: &NodeRegistry, delegated_cap_id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(&node_registry.oracle_nodes)) {
            let n = vector::borrow(&node_registry.oracle_nodes, i);
            if (n.delegated_controller_cap_id == delegated_cap_id) return true;
            i = i + 1;
        };
        false
    }

    fun is_devnet(st: &State): bool {
        let devnet = b"devnet";
        bytes_eq(&st.network, &devnet)
    }


    fun bytes_eq(a: &vector<u8>, b: &vector<u8>): bool {
        if (vector::length(a) != vector::length(b)) return false;
        let mut i = 0;
        while (i < vector::length(a)) {
            if (*vector::borrow(a, i) != *vector::borrow(b, i)) return false;
            i = i + 1;
        };
        true
    }
}
