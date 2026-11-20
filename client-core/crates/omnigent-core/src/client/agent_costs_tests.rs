//! Agent costs read a session tree's costs a thousand at a time, and tag each as the web does.

use futures::executor::block_on;

use super::AgentCost;
use crate::client::test_support::{Reply, RouteTransport, connected, path_of, query_value};

const PATH: &str = "/v1/sessions/conv_a/agent_costs";

fn cost(cost_usd: Option<f64>, estimated: Option<f64>) -> AgentCost {
    AgentCost {
        id: "conv_b".into(),
        cost_usd,
        estimated_cost_usd: estimated,
    }
}

#[test]
fn a_tag_reads_cents_a_sub_cent_floor_and_an_estimate() {
    assert_eq!(cost(Some(0.42), None).label().as_deref(), Some("$0.42"));
    assert_eq!(cost(Some(0.004), None).label().as_deref(), Some("<$0.01"));
    assert_eq!(cost(Some(0.0), None).label().as_deref(), Some("$0.00"));
    assert_eq!(cost(None, Some(0.1)).label().as_deref(), Some("~$0.10"));
    assert_eq!(cost(None, None).label(), None);
}

#[test]
fn every_page_is_read_and_a_server_without_the_route_has_none() {
    let transport = RouteTransport::local();
    transport.enqueue(
        "GET",
        PATH,
        vec![
            Reply::json(
                200,
                r#"{"object":"list","data":[{"id":"conv_a","cost_usd":1.5,"estimated_cost_usd":null}],
                    "has_more":true,"last_id":"conv_a"}"#,
            ),
            Reply::json(
                200,
                r#"{"object":"list","data":[{"id":"conv_b","cost_usd":null,"estimated_cost_usd":0.2}],
                    "has_more":false,"last_id":"conv_b"}"#,
            ),
        ],
    );
    let core = connected(transport);
    let costs = block_on(core.agent_costs("conv_a"))
        .unwrap()
        .expect("supported");
    assert_eq!(
        costs
            .iter()
            .map(|cost| cost.id.as_str())
            .collect::<Vec<_>>(),
        ["conv_a", "conv_b"]
    );
    assert_eq!(costs[1].estimated_cost_usd, Some(0.2));
    let reads: Vec<_> = core
        .transport()
        .taken()
        .into_iter()
        .filter(|request| path_of(request) == PATH)
        .collect();
    assert_eq!(query_value(&reads[0], "limit").as_deref(), Some("1000"));
    assert_eq!(query_value(&reads[1], "after").as_deref(), Some("conv_a"));

    let old = RouteTransport::local();
    old.enqueue(
        "GET",
        PATH,
        vec![Reply::json(404, r#"{"detail":"Not Found"}"#)],
    );
    let core = connected(old);
    assert_eq!(block_on(core.agent_costs("conv_a")).unwrap(), None);
}
