# Update VM Image Reference (Single-Instance VMs) — Private Preview

**Feature:** `Microsoft.Compute/ImageReferenceUpdateForSIVMs`
**Status:** Private Preview (enabled per subscription, by request)
**Scope:** Existing single-instance Azure VMs that already have an image reference. VM Scale Sets use their own image-upgrade path and are not covered here.

> ### ⚠️ Private Preview disclaimer
>
> This feature is in **Private Preview**. It is **not backed by Microsoft Support SLAs** and carries no availability, performance, or data-durability guarantees.
>
> **Do not use it in production environments.** Use it only in **dev/test or other lower environments** to validate the capability against your workloads.
>
> Preview behavior, API surface, and the request contract may change or be withdrawn without notice. Standard Azure support channels cannot assist with preview issues; see [Section 7](#7-support-and-feedback) for how to reach us.

---

## 1. What this preview gives you

Every Azure VM stores an **image reference** (`storageProfile.imageReference`): the record of which OS image the VM was created from. Azure Update Manager, Azure Monitor, Azure Policy, Defender for Cloud, Backup, and Site Recovery all read this field to decide how to manage your VM.

Until now this field was fixed at VM creation. If the guest OS changed after creation, the record went stale and stayed stale.

This preview lets you **correct the image reference on an existing VM**, with or without reimaging it.

### Who this is for

Onboard if you have VMs where the recorded image no longer matches reality:

| Scenario | What went wrong |
|---|---|
| **In-place OS upgrade** | You upgraded WS2019 to WS2022, or Windows 10 to Windows 11. The reference still names the old SKU, so patching and policy target the wrong OS. |
| **Gen1 to Gen2 / Trusted Launch conversion** | The VM is now Gen2 with Secure Boot and vTPM, but the reference still points at a Gen1 image. Hotpatch and Azure Update Manager eligibility are blocked. |
| **Deleted or invalid gallery image** | The Azure Compute Gallery image version the VM was created from was deleted. Reimage and reporting now fail. |
| **Fleet reporting is wrong** | Your OS-distribution dashboards and compliance reports do not reflect what your VMs are actually running. |

> VMs with a **null** image reference (restored from Azure Backup, Site Recovery, Azure Migrate, or built by attaching an OS disk) are **not** covered by this preview. Setting a reference on those VMs is planned for a future release.

### What this does **not** do

The platform validates that the new image is *compatible* with the VM (VM size support for generation, security type and architecture, plus region, OS type, and publisher). It does **not** inspect the guest to confirm the image actually matches the running OS, and it never will. **Choosing a truthful image reference is your responsibility.** An inaccurate reference will mislead patching and compliance just as badly as a stale one.

---

## 2. Onboard to the preview

<table>
  <thead>
    <tr>
      <th width="60">Step</th>
      <th width="200">Title</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center"><b>1</b></td>
      <td>Submit the onboarding form</td>
      <td>
        Fill out the preview request form:<br>
        <b>Onboarding form:</b> <a href="https://aka.ms/vmImageRef/PreviewOnboard">https://aka.ms/vmImageRef/PreviewOnboard</a>
        <br><br>
        You will be asked for:
        <table>
          <thead>
            <tr><th>Field</th><th>Notes</th></tr>
          </thead>
          <tbody>
            <tr><td>Organization name</td><td>Required</td></tr>
            <tr><td>Contact name and email</td><td>Required. Use an alias we can reach for preview updates.</td></tr>
            <tr><td><b>Azure subscription ID</b></td><td>Required. One response per subscription. This is what we enable.</td></tr>
            <tr><td>Approximate VM count</td><td>Optional. Helps us size rollout.</td></tr>
            <tr><td>Scenario details</td><td>Optional. Which of the scenarios above applies to you. Very helpful for prioritization.</td></tr>
          </tbody>
        </table>
      </td>
    </tr>
    <tr>
      <td align="center"><b>2</b></td>
      <td>We enable your subscription</td>
      <td>
        We enable the subscription feature <code>Microsoft.Compute/ImageReferenceUpdateForSIVMs</code> on your subscription.
        You receive a confirmation email once it is active. The preview is available in <b>Azure public cloud regions</b>,
        with no restriction between them. Allow up to 3 business days.
        <br><br>
        Need this in a national cloud (Azure Government, Azure China)? Say so in the
        <b>Anything else we should know</b> field on the form. We can take those up on request.
      </td>
    </tr>
    <tr>
      <td align="center"><b>3</b></td>
      <td>Verify and refresh the provider</td>
      <td>
        Once you receive confirmation, confirm the feature reads <code>Registered</code>, then re-register the Compute
        resource provider so the flag propagates:
<pre><code>az account set --subscription &lt;your-subscription-id&gt;
&#35; Confirm the feature shows as Registered
az feature show --namespace Microsoft.Compute --name ImageReferenceUpdateForSIVMs --query properties.state -o tsv
&#35; Propagate the registration to the resource provider (takes a few minutes)
az provider register --namespace Microsoft.Compute</code></pre>
        Expected output from the first command: <code>Registered</code>. If it returns <code>NotRegistered</code>
        or the command errors, reply to your onboarding email before proceeding.
      </td>
    </tr>
    <tr>
      <td align="center"><b>4</b></td>
      <td>Update your VMs</td>
      <td>Follow Section 3. Start with one non-production VM before running this across a fleet.</td>
    </tr>
  </tbody>
</table>

### Prerequisites

- **Permissions:** `Microsoft.Compute/virtualMachines/write` on the target VM (Virtual Machine Contributor, Contributor, or Owner). For gallery targets you also need read access to the gallery image version.
- **VM type:** Single-instance VM only. Not a VMSS instance.
- **Clouds and regions:** Azure public cloud only. Once your subscription is enabled, the feature works in every public cloud region available to it, with no restriction between them. National clouds (Azure Government, Azure China) are not enabled by default but can be taken up on request.
- **API version:** `2024-11-01` or later. Earlier API versions reject the update.
- **Tooling:** Azure CLI 2.60+ (for `az rest`) or Az PowerShell 12.0+.

---

## 3. Use the feature

Two modes:

| Mode | What happens | Reboot / data loss |
|---|---|---|
| **Metadata-only** (default) | Only the control-plane record changes. OS disk and running guest are untouched. | None. VM keeps running. |
| **Update + reimage** | The record changes **and** the OS disk is reset from the new image. | OS disk is wiped and rebuilt. Data disks, NICs, and VM identity are preserved. |

Reimage is opt-in through a VM resource tag, described in 3.2.

### 3.1 Metadata-only update

This is the mode most customers want after an in-place OS upgrade. Which properties you set depends on where the image comes from:

| Image source | Property to set |
|---|---|
| Platform / Marketplace image | `publisher`, `offer`, `sku`, `version` |
| Azure Compute Gallery (RBAC) | `id` (gallery **image version** resource ID) |
| Direct shared gallery | `sharedGalleryImageId` |
| Community gallery | `communityGalleryImageId` |

On an existing third-party Marketplace VM, leave the root-level `plan` block untouched. Plan fields are immutable.

**REST (Azure CLI)** — platform / Marketplace image:

```powershell
az rest --method PATCH `
  --url "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<vm>?api-version=2024-11-01" `
  --headers "Content-Type=application/json" `
  --body '{
    "properties": {
      "storageProfile": {
        "imageReference": {
          "publisher": "MicrosoftWindowsServer",
          "offer": "WindowsServer",
          "sku": "2022-datacenter-azure-edition",
          "version": "latest"
        }
      }
    }
  }'
```

**REST** — Azure Compute Gallery image version:

```powershell
az rest --method PATCH `
  --url "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<vm>?api-version=2024-11-01" `
  --headers "Content-Type=application/json" `
  --body '{
    "properties": {
      "storageProfile": {
        "imageReference": {
          "id": "/subscriptions/<sub-id>/resourceGroups/<gallery-rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<imageDefinition>/versions/<version>"
        }
      }
    }
  }'
```

**PowerShell** (`Update-AzVM`):

```powershell
$vm = Get-AzVM -ResourceGroupName <rg> -Name <vm>
$vm.StorageProfile.ImageReference.Publisher = "MicrosoftWindowsServer"
$vm.StorageProfile.ImageReference.Offer     = "WindowsServer"
$vm.StorageProfile.ImageReference.Sku       = "2022-datacenter-azure-edition"
$vm.StorageProfile.ImageReference.Version   = "latest"
Update-AzVM -ResourceGroupName <rg> -VM $vm
```

> **Azure CLI note:** `az vm update --set storageProfile.imageReference.*` does **not** work in this preview. Use `az rest` or PowerShell. Native `az vm` support is planned for a future release.

### 3.2 Update + reimage

Reimage is driven by a **VM resource tag**, not a request body property. Set the tag immediately before the PATCH:

```powershell
az tag update `
  --resource-id "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<vm>" `
  --operation Merge --tags ReimageOnImageReferenceUpdate=true
```

Then issue the PATCH. A reimaging PATCH **must** include `osProfile.adminPassword`; the request is rejected with `OperationNotAllowed` otherwise. Any valid password works, it does not have to match the VM's original password.

```powershell
az rest --method PATCH `
  --url "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<vm>?api-version=2024-11-01" `
  --headers "Content-Type=application/json" `
  --body '{
    "properties": {
      "storageProfile": {
        "imageReference": {
          "publisher": "MicrosoftWindowsServer",
          "offer": "WindowsServer",
          "sku": "2022-datacenter-azure-edition",
          "version": "latest"
        }
      },
      "osProfile": { "adminPassword": "<any-valid-password>" }
    }
  }'
```

> **Set the tag explicitly on every update.** A leftover `ReimageOnImageReferenceUpdate=true` tag from a previous operation will reimage your VM on the next reference change. Set it to `false` when you want a metadata-only update on a VM that has previously used reimage.

**What reimage preserves:** VM identity, NICs, data disks, extensions configuration, tags.
**What reimage destroys:** everything on the OS disk.

### 3.3 Verify the result

```powershell
az vm show -g <rg> -n <vm> --query "storageProfile.imageReference" -o json
```

If you corrected a reference to restore patching eligibility, also confirm in **Azure Update Manager** within 24 hours that the VM now appears with the correct applicable patches. For Trusted Launch VMs, confirm **Portal → VM → Security → Attestation** still reports success.

---

## 4. What is allowed

Setting a reference on a VM that currently has **none** (null) is not available in this preview. Everything else below is in scope.

| Current reference | New reference | Allowed |
|---|---|---|
| Platform / Marketplace image | Platform / Marketplace image, **same publisher** | Yes |
| Platform / Marketplace image | Gallery image | Yes |
| Gallery image | Platform / Marketplace image | Yes |
| Gallery image | Gallery image | Yes |
| Managed image (legacy) | Gallery image definition | Yes |
| Any | Managed image (legacy) | No |
| Any | Null | Accepted, but ignored. The existing reference is left unchanged. |
| Null | Any | Not in this preview |

Every allowed transition is additionally validated for:

- **VM size compatibility:** the VM's size must support the target image's Hyper-V generation, security type, and CPU architecture. A Gen1-only size cannot take a Gen2 image, and an x64 size cannot take an Arm64 image.
- **Security type already in effect:** if the VM is already running with a security type such as Trusted Launch, the target image must declare support for it (for example `TrustedLaunchSupported` or `TrustedLaunch`). You cannot point a Trusted Launch VM at an image that does not support Trusted Launch.
- **OS type** must match (Windows to Windows, Linux to Linux).
- **Region:** the image must be available or replicated in the VM's region.
- **Publisher:** for platform-image to platform-image updates, the publisher must stay the same. `offer`, `sku`, and `version` may change.
- **Marketplace plan** fields (`plan.publisher`, `plan.product`, `plan.name`, `plan.promotionCode`) are immutable on an existing Marketplace VM.
- **Image existence:** the target must resolve. Deleted gallery versions and unknown publisher/offer/sku combinations are rejected.

Validation is **atomic and fail-fast**. A rejected request leaves the VM's existing reference completely untouched, and rejection happens before any disk operation begins.

Repeating an identical update is a safe no-op.

---

## 5. Error reference

Failures return HTTP 4xx with top-level code `InvalidImageReference` and a detail code:

| Detail code | Meaning | Fix |
|---|---|---|
| `IncompatibleGeneration` | Image Hyper-V generation does not match the VM. | Pick an image matching the VM's generation, or upgrade the VM to Gen2 first. |
| `IncompatiblesecurityType` | Image does not support the VM's security type. | Pick a Trusted Launch or Confidential VM capable image, as applicable. |
| `IncompatibleArchitecture` | Image architecture is unsupported by the VM size. | Match x64 or Arm64 to the VM family. |
| `IncompatibleRegion` | Image is not available in the VM's region. | Replicate the gallery image version to the VM's region. |
| `InvalidImagePublisher` | Platform-image update crosses publishers. | Stay within the same publisher. |
| `InvalidImageReference` | Image does not exist, or the target is an unsupported type (for example a managed image). | Verify the publisher/offer/sku or gallery version ID. Migrate managed images to a gallery image definition. |
| `OtherConfigurationMismatch` | Another VM-versus-image incompatibility. | Compare VM configuration against the image definition properties. |
| `PropertyChangeNotAllowed` | Surfaced today for generation and some security-type rejections. | Same remedy as `IncompatibleGeneration` / `IncompatiblesecurityType`. |
| `OperationNotAllowed` | Reimage requested without `osProfile.adminPassword`. | Add `osProfile.adminPassword` to the request body. |

---

## 6. Scope, limitations, and known issues

### By design (will not change)

- **No guest OS validation, ever.** The platform will not inspect the guest to confirm your chosen image matches the OS actually running inside the VM. This is intentional and permanent. An inaccurate reference will mislead patching, policy, and compliance just as badly as a stale one. Verify the running OS before you set the value.
- **Single-instance VMs only.** VM Scale Sets are not covered by this feature because VMSS already supports changing the image reference through its own image-upgrade path. Use that path for scale sets.

### Preview limitations

1. **Azure CLI has no native support.** `az vm update` cannot set `imageReference`. Use `az rest`, PowerShell, or ARM/Bicep.
2. **Portal support is not available** in this preview. The VM Configuration blade cannot set the image reference yet.
3. **Reimage is tag-driven, not a body property.** `reimageOnImageUpdate` as a request body field is **not** accepted on any currently registered API version. Use the `ReimageOnImageReferenceUpdate` tag as shown in 3.2. The typed property arrives with a future API version.
4. **Null to non-null is not included.** VMs with no image reference at all cannot have one set in this preview. See Section 4.
5. **API version.** The preview is supported on API version `2024-11-01` and later. The API version for general availability has not been finalized, so scripts written against the preview may need updating.

### Known issues

- **OS-type mismatch is not currently blocked.** Setting a Windows image on a Linux VM (or vice versa) may be accepted rather than rejected. Do not rely on the platform to catch this. A fix is tracked.
- **Reimage can fail on VMs whose OS disk was attached** (`createOption=Attach`), including Backup, Site Recovery, and Azure Migrate restores. This is a **pre-existing platform behavior**, not caused by or specific to this feature. Metadata-only updates on those VMs are unaffected.

### Validated as safe

The corrected reference persists across deallocate/start, restart, redeploy, resize, extension install and uninstall, data disk attach and detach, and snapshot. Reimage preserves data disks and NICs. Metadata-only updates cause no reboot and no billing meter change.

---

## 7. Support and feedback

- **Onboarding issues, feature registration:** reply to your onboarding confirmation email.
- **Bugs, unexpected errors, feature requests:** submit the **preview feedback form** at <https://aka.ms/vmImageRef/PreviewFeedback>. Use the form rather than free-form email so reports arrive in a consistent, triageable format.
- **Do not open a standard Azure support ticket** for preview issues; support engineers do not have context on this preview. Use the feedback form instead.

The feedback form asks for:

| Field | Notes |
|---|---|
| Subscription ID | Required |
| VM resource ID | Required. Full ARM ID. |
| Date of the failed request | Required. Lets us locate the operation in platform telemetry. |
| Correlation ID | Optional but valuable. From the `x-ms-correlation-request-id` response header or the Activity Log entry. Add the time and time zone here too. |
| What you were trying to do | Required. Metadata-only update or update + reimage. |
| API version used | Required |
| Full request body | Required. Redact any password before submitting. |
| Complete error response | Required if the request failed. Include the top-level and detail error codes. |
| Expected vs actual behavior | Required |
| Whether the VM was left in a bad state | Required. A rejected request should leave your VM untouched; tell us if it did not. |
| Severity / blocking status | Required. Tell us if this blocks your validation. |

File **one response per issue**. Batching several problems into a single submission slows triage.

Tell us what worked and what did not. Preview feedback directly shapes the GA contract, especially around metadata-only semantics, tooling coverage, and the reimage opt-in mechanism.
