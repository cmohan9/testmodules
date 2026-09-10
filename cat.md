# User Guide for Raising a Request — CyberArk Endpoint Privilege Manager (EPM)

<span style="color:red"><strong>Note:</strong></span> This article follows the KB Articles Creation, Standards and KB Articles Attachment guidelines (per KB0012505). A new revision history entry must be added every time this article's content is modified — see the **Revision History** table below.

---

## Revision History

| Version | Date (mm/dd/yyyy) | Description of Change | Author |
|---|---|---|---|
| 1.0 | 09/10/2026 | Initial document | cmohan9@deloitte.com |
| 1.1 | 09/10/2026 | Added FAQ section covering AD groups, catalog service selection, the Describe the Issue field, EPM policy explanation, approval on changed requests, group-based requests, and the requirement gathering form | cmohan9@deloitte.com |
| 1.2 | 09/10/2026 | Converted the article to Markdown format with structured headers, callouts, and tables for readability | cmohan9@deloitte.com |
| 1.3 | 09/10/2026 | Reorganized the FAQ into a systematic learning-flow order (22 questions); removed emoji usage throughout the article | cmohan9@deloitte.com |
| 1.4 | 09/10/2026 | Aligned article structure to KB Creation and Standards template: added Revision History, Introduction, and Article Metadata sections; applied a/b/c and i/ii/iii numbering; formatted notes in red/bold | cmohan9@deloitte.com |

---

## Introduction

This article provides guidance for users in the **Japan (JP) Region** on how to raise a ServiceNow catalog request for CyberArk Endpoint Privilege Manager (EPM) — either **Temporary Administrator Access (JIT)** or **EPM Policy Creation/Modification** — and includes a Frequently Asked Questions (FAQ) section addressing common user questions about EPM, when to use each request type, and how to complete the request correctly.

**Applicable region(s):** Japan (JP) only. The Request/Manage Admin Rights catalog contains options for other regions as well; JP users must use only the option identified in this article.

---

## Raise a ServiceNow Request — Request/Manage Admin Rights

Use the link below to access the **Request/Manage Admin Rights** Service Catalog to request:

- **Temporary Administrator Access (JIT)**, or
- **EPM Policy Creation/Modification**

through CyberArk Endpoint Privilege Manager (EPM).

> **Navigation:** All Catalogs → GITO Catalog → Security → **Request/Manage Admin Rights**

<span style="color:red"><strong>Important:</strong></span> Under **Services Required**, users must select **"Request assistance with CyberArk Endpoint Privilege Manager (EPM)"** only. This option is specifically for the **Japan (JP) Region**. The remaining options in the catalog are intended for other regions and **must not** be used for JP EPM requests.

---

## 1. Temporary Administrator Access (JIT)

Request temporary administrator access when device-wide elevated privileges are required to perform approved business activities on your endpoint.

### a. Select the Service

Under **Services Required**, select:

> `Request assistance with CyberArk Endpoint Privilege Manager (EPM)`

### b. Provide the Required Information

**i. Business Justification**

Clearly explain:

- Why temporary administrator access is required.
- The business impact if access is not granted.
- The task or activity being performed.
- Any project, operational, or application-related requirements that necessitate elevated privileges.

**ii. Description**

Provide additional details, including:

- Device/Computer Name.
- Purpose of the activity.
- Expected duration of access (**maximum 3 hours**).
- Any relevant supporting information, such as application name, installation details, or business deadlines.

**iii. Describe the Issue**

Please enter the following **exactly** as shown:

```
Requesting JP Temp Admin Access (JIT)
```

<span style="color:red"><strong>Note:</strong></span> Ensure sufficient business justification and supporting details are provided to avoid delays during the approval and fulfillment process.

**iv. Submit the request.**

### c. Approval & Fulfillment Process

i. Request is submitted through Quest.
ii. Request is routed to the requester's manager for approval.
iii. Once approved, the request is assigned to the CyberArk EPM Team for review and processing.

> **SLA:** Temporary Administrator Access (JIT) is processed **within 4 hours** of receipt after manager approval.

---

## 2. EPM Policy Creation / Modification Request

Request creation of a new EPM elevation policy or modification of an existing policy for application elevation requirements.

### a. Select the Service

Under **Services Required**, select:

> `Request assistance with CyberArk Endpoint Privilege Manager (EPM)`

### b. Provide the Required Information

**i. Business Justification**

Clearly provide the following details:

- The business requirement for application elevation or policy creation/modification.
- The impact to users or business operations if the requested elevation is not provided.
- The team, department, or user group affected.
- The number of users requiring elevation.
- Any relevant approvals, project references, or supporting business requirements.

**ii. Description**

Provide complete application and policy details, including:

- Application Name
- Application Version
- Executable File Name and/or File Path
- Application Publisher Information
- Whether the request is for a **New Policy Creation** or an **Existing Policy Modification**
- User Group, Department, or Team requiring the policy
- Any supporting documentation, screenshots, or additional information that may assist in evaluating the request

**iii. Describe the Issue**

Please enter the following **exactly** as shown:

```
Request for JP EPM Policy Creation/Modification
```

**iv. Submit the request.**

### c. Approval & Fulfillment Process

i. Request is submitted through Quest.
ii. Request is routed to the requester's manager for approval.
iii. Once approved, the request is assigned to the CyberArk EPM Team for review and processing.

> **SLA:** Policy Creation/Modification is processed **within 3 business days**, provided all required information and relevant details are included in the request.

**Processing may be delayed if:**

i. Additional information or clarification is required.
ii. There is a delay in responses from the requestor.
iii. Further analysis, validation, or review is needed before implementation.

---

## Frequently Asked Questions (FAQ)

The questions below are organized in a logical order — starting from the basics of EPM, moving through when and how to raise a request, and ending with special cases. Read them in sequence if you are new to EPM.

### Understanding EPM

**Q1. What is CyberArk Endpoint Privilege Manager (EPM)?**

CyberArk EPM is a security tool that controls which applications on your device are allowed to run with administrator (elevated) rights. Instead of giving users permanent, device-wide administrator access, EPM allows elevation only for specific, approved applications or for a limited time — reducing the risk of malware, unauthorized software, or accidental system changes.

**Q2. Why has local admin access been removed for users?**

Standing (permanent) local administrator access on a device is a significant security risk — if the device or account is compromised, the attacker also gets full administrator control. To reduce this risk, organizations remove permanent local admin rights and instead give users **standard user rights** by default. When elevated rights are genuinely needed, users can request them through EPM, either temporarily (JIT) or through an approved policy for a specific application. This is a security control, not a restriction on the user's ability to do their job.

**Q3. What is an EPM policy, and why is an application blocked even though I need it for work?**

An EPM policy is a rule configured in CyberArk EPM that allows a specific, named application to run with elevated rights automatically, without the user needing admin access to the whole device. If an application needs elevated rights to install, update, or run, and no EPM policy currently covers it, EPM will block it by default — this is expected, normal behavior, not a fault with the application. The fix is to raise a Policy Creation/Modification request so that application is specifically allowed to run with elevation for the intended users.

**Q4. What is Temporary Administrator Access (JIT)?**

JIT (Just-In-Time) Access gives a user full, device-wide administrator rights for a short, defined period (maximum 3 hours) to complete a specific, approved task. Once the time period ends, the elevated access is automatically removed, and the device returns to standard user rights.

**Q5. What is the difference between a JIT request and an EPM Policy request?**

| | JIT (Temporary Admin Access) | EPM Policy Creation/Modification |
|---|---|---|
| Scope | Full device-wide admin rights | Elevated rights for one specific, named application only |
| Duration | Temporary — maximum 3 hours | Ongoing, until the policy is modified or removed |
| Use case | A one-time or short-term task requiring broad admin access | Regular, repeated use of a specific application that needs elevation |
| Applies to | The individual requester's device | A user, a team, or an AD group |
| Typical processing time | Within 4 hours after manager approval | Within 3 business days after manager approval |

### When to Raise Each Type of Request

**Q6. In which case should I raise a JIT request?**

Raise a JIT request when you need short-term, device-wide administrator access to complete a specific, approved activity — for example, installing a one-off tool, troubleshooting a device issue, or performing a task that does not repeat regularly and does not justify a permanent policy. Use JIT only when the need is temporary and clearly time-bound (up to 3 hours).

**Q7. In which case should I raise a Policy Creation/Modification request?**

Raise a Policy request when a specific application consistently needs elevated rights to install, update, or run for you or your team on an ongoing basis. Instead of repeatedly requesting temporary access, a policy permanently allows that one application to run elevated for the approved users, without granting broader device-wide admin rights. Also raise a Policy Modification request if an existing policy needs a change, such as a new application version, an updated file path, or an updated user group.

### How to Raise a Request

**Q8. Where do I go to raise a request?**

Navigate to: All Catalogs → GITO Catalog → Security → Request/Manage Admin Rights. This single catalog item is used for both JIT requests and Policy Creation/Modification requests.

**Q9. Which option should I select under "Services Required"?**

Always select "Request assistance with CyberArk Endpoint Privilege Manager (EPM)". This is the only option meant for JP region EPM requests, for both JIT and Policy requests. All other options in the catalog belong to different regions or services. Selecting the correct option is what allows your request to be routed to the CyberArk EPM Team — selecting the wrong option will delay or misroute your request.

### Filling in the Request Correctly

**Q10. What should I include in the Business Justification field?**

For a JIT request, explain why temporary administrator access is needed, the business impact if it is not granted, the task being performed, and any related project or operational requirement. For a Policy request, explain the business requirement for the elevation or policy, the impact if it is not provided, the team or group affected, and the number of users who need it.

**Q11. What should I include in the Description field for a JIT request?**

Include the device/computer name, the purpose of the activity, the expected duration of access (maximum 3 hours), and any supporting information such as application name, installation details, or business deadlines.

**Q12. What should I include in the Description field for a Policy request?**

Include the application name, application version, executable file name and/or file path, publisher information, whether this is a new policy or a modification of an existing one, and the user group, department, or team requiring the policy. Attach any supporting documentation or screenshots that may help the EPM Team evaluate the request.

**Q13. What should I enter in the "Describe the Issue" field — does it really matter?**

Yes, it matters, and the exact wording should be used:

| Request Type | Text to Enter |
|---|---|
| Temporary Administrator Access (JIT) | `Requesting JP Temp Admin Access (JIT)` |
| Policy Creation/Modification | `Request for JP EPM Policy Creation/Modification` |

This exact text allows the EPM Team to immediately identify and separate time-sensitive JIT requests from Policy requests as soon as they arrive, so JIT requests can be processed within their committed 4-hour window without delay.

### Approval, Processing, and Delays

**Q14. Who approves my request, and what happens after I submit it?**

The request is first submitted through Quest and routed to the requester's manager for approval. Once the manager approves it, the request is assigned to the CyberArk EPM Team, who review and process it.

**Q15. How long does it take to process a JIT request or a Policy request?**

A JIT (Temporary Administrator Access) request is processed within 4 hours of receipt after manager approval. A Policy Creation/Modification request is processed within 3 business days, provided all required information is included.

**Q16. What can cause delays in processing?**

Processing may be delayed if additional information or clarification is required, if there is a delay in the requestor's responses, or if further analysis, validation, or review is needed before implementation. Providing complete and accurate details up front, in Business Justification, Description, and Describe the Issue, helps avoid these delays.

### Requests for Teams and Groups

**Q17. Can one request cover a whole team, or does every member need to raise a separate request?**

One request is enough for a whole team. If 20 members of a team all need the same policy, they do not need to raise 20 separate requests. A single Policy Creation/Modification request can be raised for the group, referencing the relevant Active Directory (AD) group instead of listing individual users.

**Q18. How do I specify a group of users in my request?**

In the Description field, provide the name of the existing AD group that should receive the policy, along with the application details. Using an AD group, instead of listing individual usernames, allows the EPM Team to apply the policy to all current members at once, and it continues to apply correctly if group membership changes later.

**Q19. What if my team does not have an existing AD group?**

If a suitable AD group does not already exist, reach out to the UAM (User Access Management) team through the catalog link `[insert UAM/AD group creation catalog link]` to get a new AD group created first. Once the group is created, reference it in your EPM Policy Creation/Modification request.

### Changes After Approval

**Q20. What happens if the application details or the list of users change after discussion with the EPM Team, or after approval?**

The EPM Team creates and applies the policy strictly based on what was reviewed and approved. If the application details (name, version, publisher, and so on) or the affected users/group change after submission or during discussion, this is treated as a modified request and requires fresh manager approval for the updated details before the EPM Team can proceed.

**Q21. Can I request additional changes after my policy has already been approved and created?**

If you need changes beyond what was already approved and fulfilled, raise a new Policy Creation/Modification request describing the additional changes. Do not expect additional or unapproved changes to be added under the original request.

### Preparing Your Request

**Q22. Is there a form or template to help me prepare the details before raising a request?**

Yes. Use the Requirement Gathering Form `[attached/linked to this catalog]` to collect all necessary details in advance, including application name, version, executable/file path, publisher, whether it is a new policy or a modification, and the affected user group or AD group. Completing this form before you raise the request helps avoid delays caused by missing information during review.

---

## ServiceNow Article Metadata

*Confirm each field below against the values actually available in the SNOW ticket fields/Knowledge form before publishing (per KB Creation and Standards, item g).*

| Field | Value |
|---|---|
| Knowledge Base | G_IT_KM |
| Tower Name | `[Insert Tower Name]` |
| Category | Security *(confirm against available Category options)* |
| Subcategory | Privileged Access Management *(confirm against available Subcategory options)* |
| Business Service | CyberArk Endpoint Privilege Manager (EPM) *(confirm against available Business Service options)* |
| Language | English |
| Region(s) | Japan (JP) |
| Can Read | ITIL-role agents; JP region end users (this article is intended for end-user self-service) |
| Cannot Read | `[Define if view needs to be restricted/segregated by region]` |
| Meta Words (Search Words) | EPM, CyberArk, Endpoint Privilege Manager, JIT, Temporary Admin Access, Policy Creation, Policy Modification, Elevation, Admin Rights, ServiceNow Catalog, Japan, JP, AD Group |
| Resolver Group | CyberArk EPM Team *(if the EPM process described here does not resolve the issue, route per your team's standard assignment group)* |

---

**Formatting note for transfer to the official SNOW KB template:** This Markdown file is a content source. When pasting into the official KB Word template for upload to ServiceNow, apply Candara or Tahoma font throughout, title font size 14–16, general content font size 12, and confirm the numbering (1/2/3, a/b/c, i/ii/iii) carries over correctly, per the KB Creation and Standards article.

**Open placeholders to resolve before publishing:**
- Q19 / ServiceNow Article Metadata — UAM team catalog link for AD group creation
- Q22 — Requirement Gathering Form attachment/link
- ServiceNow Article Metadata — Tower Name, Cannot Read, and confirmed Category/Subcategory/Business Service values
