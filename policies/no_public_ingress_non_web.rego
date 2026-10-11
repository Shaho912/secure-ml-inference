# METADATA
# title: Public ingress is allowed only on HTTP/HTTPS
# description: |
#   Project invariant: the only thing reachable from the internet is the ALB on 80/443.
#   Trivy's built-in AWS-0107 only flags administrative ports (22/3389), so a rule opening
#   e.g. the app port 8000 to 0.0.0.0/0 would pass the scan. This check closes that gap.
#   It runs on Trivy's normalized AWS model, so it covers aws_security_group inline rules,
#   aws_security_group_rule, and aws_vpc_security_group_ingress_rule alike.
# scope: package
# schemas:
#   - input: schema["cloud"]
# custom:
#   id: SMI-0001
#   avd_id: SMI-0001
#   provider: aws
#   service: ec2
#   severity: CRITICAL
#   short_code: no-public-ingress-except-web
#   recommended_action: Allow ingress from a security group (e.g. the ALB's), not a public CIDR.
#   input:
#     selector:
#       - type: cloud
#         subtypes:
#           - service: ec2
#             provider: aws
package user.aws.ec2.smi0001

import rego.v1

public_cidrs := {"0.0.0.0/0", "::/0"}

web_ports := {80, 443}

deny contains res if {
	some sg in input.aws.ec2.securitygroups
	some rule in sg.ingressrules
	some cidr in rule.cidrs
	cidr.value in public_cidrs
	not web_only(rule)
	res := result.new(
		sprintf("Security group rule allows ingress from %s on ports %d-%d", [cidr.value, rule.fromport.value, rule.toport.value]),
		cidr,
	)
}

web_only(rule) if {
	rule.fromport.value == rule.toport.value
	rule.fromport.value in web_ports
}
