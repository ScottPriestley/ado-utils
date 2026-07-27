# Azure DevOps Process Field Extraction Scripts (PowerShell) 
## “All Fields for a Specific ADO Process + CSV Export”
## Overview
This repository contains two PowerShell scripts designed to help Azure DevOps (ADO) administrators, architects, and process owners extract field metadata from ADO processes. These scripts are useful for documentation, audits, migration planning, and governance work.

### 1. ado-organization-ID-listing.ps1
Azure DevOps no longer exposes the process GUID in the UI.
Use this PowerShell script to list all processes and their IDs for use in the next step.

### 2. ado-process-fields.ps1
Retrieves all fields for a specific Azure DevOps Process, including:
- Work Item Type
- Field Name
- Reference Name
- Data Type
- Required / ReadOnly flags
- Inherited status

This script consolidates all fields across all Work Item Types (WITs) in the process.
The consolidated field list is exported to a CSV file.

Output file: ADO_Process_Fields.csv

### Prerequisites
Azure DevOps Personal Access Token (PAT)
You must generate a PAT with at least:
- Work Items (Read) permission

Create PAT via:
Azure DevOps → User Settings → Personal Access Tokens → New Token

PowerShell
Both scripts run on:
- Windows PowerShell
- PowerShell Core (macOS/Linux)
