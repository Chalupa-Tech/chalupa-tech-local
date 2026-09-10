resource "oci_core_vcn" "oracle_server" {
  compartment_id = var.compartment_ocid
  display_name   = "oracle-server-vcn"
  cidr_blocks    = ["10.30.0.0/16"]
  dns_label      = "oracleserver"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "oracle-server-igw"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "oracle-server-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# Deliberately NOT the default security list: no SSH ingress. Game traffic
# is admitted by the NSG below; Tailscale rides outbound UDP (egress only).
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "oracle-server-public-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Path MTU discovery (fragmentation needed)
  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.oracle_server.id
  cidr_block        = "10.30.1.0/24"
  display_name      = "oracle-server-public"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
}

resource "oci_core_network_security_group" "valheim" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.oracle_server.id
  display_name   = "valheim-nsg"
}

resource "oci_core_network_security_group_security_rule" "valheim_udp" {
  network_security_group_id = oci_core_network_security_group.valheim.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  udp_options {
    destination_port_range {
      min = 2456
      max = 2457
    }
  }
}
