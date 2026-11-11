#!/usr/bin/env bash
# Checkpoint 6 of the Cloud project: is everything that bills really gone?
# Read-only. Run it after Phase 6, in the same Region you built in.
#
#   bash scripts/teardown-check.sh

set -uo pipefail

fail=0
check() {  # $1 label, $2 output that must be empty, $3 what to do
  if [ -z "$2" ]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1: $2"
    echo "        -> $3"
    fail=$((fail + 1))
  fi
}

echo "Cloud project: teardown check"
echo

check "No NAT gateways" \
  "$(aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text)" \
  "VPC, NAT gateways, Delete. This is the one that costs the most."

check "No Elastic IPs allocated" \
  "$(aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text)" \
  "VPC, Elastic IPs, Release. An unattached one still bills every hour."

check "No instances left" \
  "$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)" \
  "EC2, Instances, Terminate both."

check "course-vpc is deleted" \
  "$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=course-vpc --query 'Vpcs[].VpcId' --output text)" \
  "Delete the subnets, route tables, security groups and IGW, then the VPC."

echo
if [ "$fail" -eq 0 ]; then
  echo "Clean. Nothing from this project is billing."
else
  echo "$fail thing(s) still there. Delete them in reverse build order and run this again."
fi
exit "$fail"
