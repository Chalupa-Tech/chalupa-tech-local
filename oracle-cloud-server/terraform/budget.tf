# Spend tripwire for the Pay-As-You-Go upgrade. The whole stack is
# always-free-eligible and should bill $0; OCI budgets cannot hard-cap
# spending (no such mechanism exists on PAYG), so this alerts instead:
# email when actual or forecast spend crosses the monthly budget.
resource "oci_budget_budget" "monthly" {
  # Budgets must live in the tenancy root compartment.
  compartment_id = var.tenancy_ocid
  display_name   = "oracle-server-budget"
  description    = "Tripwire: this stack is always-free and should bill $0"
  amount         = var.budget_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.compartment_ocid]
}

resource "oci_budget_alert_rule" "actual" {
  budget_id      = oci_budget_budget.monthly.id
  display_name   = "actual-100pct"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "OCI actual spend crossed the oracle-server monthly budget - expected $0, investigate."
}

resource "oci_budget_alert_rule" "forecast" {
  budget_id      = oci_budget_budget.monthly.id
  display_name   = "forecast-100pct"
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "OCI forecast spend will cross the oracle-server monthly budget - expected $0, investigate."
}
