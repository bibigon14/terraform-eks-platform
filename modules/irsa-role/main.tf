# IRSA, spelled out by hand instead of hidden behind a black-box module -
# this is the actual mechanism worth understanding for an interview:
#
# 1. The EKS cluster exposes an OIDC identity provider (created because
#    enable_irsa = true on the eks module).
# 2. A pod's ServiceAccount is annotated with this role's ARN.
# 3. EKS's Pod Identity webhook injects a projected service-account token
#    into the pod and sets AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN env vars.
# 4. The AWS SDK in the pod calls sts:AssumeRoleWithWebIdentity using that
#    token. STS validates the token against the OIDC provider and checks
#    the "sub" claim matches system:serviceaccount:<namespace>:<name> below
#    before handing back short-lived credentials.
#
# No long-lived AWS keys ever touch the pod, and the blast radius of a
# compromised pod is exactly the policy_arns attached below - not the
# entire node's instance profile.

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset(var.policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}
