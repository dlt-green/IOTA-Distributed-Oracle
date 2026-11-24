#[test_only]
module iota_oracle_system_state::registration_tests {
    use iota::test_scenario::{Self, Scenario};
    use iota_oracle_system_state::systemState::{Self, NodeRegistry, State};
    use iota_oracle_validator_caps::validator_caps::{Self, DelegatedControllerCap};
    use iota_system::iota_system::IotaSystemState;
    use iota_system::validator_cap::UnverifiedValidatorOperationCap;
    use iota_system::governance_test_utils::set_up_iota_system_state;

    fun setup(): Scenario {
        let mut s = test_scenario::begin(@0x0);
        set_up_iota_system_state(vector[@0x11, @0x12]);
        systemState::init_for_testing(s.ctx());
        s.next_tx(@0x11);
        let cap = s.take_from_sender<UnverifiedValidatorOperationCap>();
        validator_caps::mint_delegated_controller_cap(&cap, @0xa, s.ctx());
        s.return_to_sender(cap);
        s.next_tx(@0xa);
        s
    }

    fun register(s: &mut Scenario, oracle: address) {
        let mut registry = s.take_shared<NodeRegistry>();
        let state = s.take_shared<State>();
        let mut system = s.take_shared<IotaSystemState>();
        let cap = s.take_from_sender<DelegatedControllerCap>();
        systemState::register_oracle_node(
            &mut registry, &state, &mut system, &cap, oracle, vector[1], vector[9], s.ctx(),
        );
        s.return_to_sender(cap);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(state);
        test_scenario::return_shared(system);
    }

    #[test]
    fun delegated_registration_and_update() {
        let mut s = setup();
        let state = s.take_shared<State>();
        // Fresh publication retains the previously approved task configuration.
        assert!(systemState::task_template_scheduler_fee_iota(&state, 9) == 21323200, 104);
        test_scenario::return_shared(state);
        s.next_tx(@0xa);
        register(&mut s, @0xa);
        s.next_tx(@0xa);
        register(&mut s, @0xa);
        s.next_tx(@0xa);
        let registry = s.take_shared<NodeRegistry>();
        let nodes = systemState::oracle_nodes(&registry);
        assert!(vector::length(nodes) == 1, 100);
        let node = vector::borrow(nodes, 0);
        assert!(systemState::oracle_node_addr(node) == @0xa, 101);
        assert!(systemState::oracle_node_accepts_template(node, 9), 102);
        assert!(systemState::oracle_node_delegated_controller_cap_id(node) != object::id(&registry), 103);
        test_scenario::return_shared(registry);
        s.end();
    }

    #[test]
    #[expected_failure(abort_code = 7, location = iota_oracle_system_state::systemState)]
    fun dev_registration_without_cap_rejected() {
        let mut s = test_scenario::begin(@0xa);
        systemState::init_for_testing(s.ctx());
        s.next_tx(@0xa);
        let mut registry = s.take_shared<NodeRegistry>();
        systemState::register_oracle_node_dev(&mut registry, @0xa, vector[1], vector[9], s.ctx());
        test_scenario::return_shared(registry);
        s.end();
    }

    #[test]
    #[expected_failure(abort_code = 7, location = iota_oracle_system_state::systemState)]
    fun dev_registration_for_another_address_rejected() {
        let mut s = test_scenario::begin(@0xa);
        systemState::init_for_testing(s.ctx());
        s.next_tx(@0xa);
        let mut registry = s.take_shared<NodeRegistry>();
        systemState::register_oracle_node_dev(&mut registry, @0xb, vector[], vector[0, 9], s.ctx());
        test_scenario::return_shared(registry);
        s.end();
    }

    #[test]
    #[expected_failure(abort_code = 8, location = iota_oracle_system_state::systemState)]
    fun delegated_registration_cannot_impersonate_node() {
        let mut s = setup();
        register(&mut s, @0xb);
        s.end();
    }

    #[test]
    #[expected_failure(abort_code = 68, location = iota_oracle_system_state::systemState)]
    fun transferred_cap_cannot_register_second_node() {
        let mut s = setup();
        register(&mut s, @0xa);
        s.next_tx(@0xa);
        let cap = s.take_from_sender<DelegatedControllerCap>();
        transfer::public_transfer(cap, @0xb);
        s.next_tx(@0xb);
        register(&mut s, @0xb);
        s.end();
    }
}
