/**
 * Invocable Apex action for the Nimbus Account Assistant Billing topic.
 *
 * Deterministic balance computation lives here, NOT in the LLM: the agent
 * passes a customer name, Apex queries invoices and sums the outstanding
 * amount. This guarantees the number is correct and auditable.
 */
public with sharing class NimbusBillingAction {

    public class Request {
        @InvocableVariable(
            label='Customer Name'
            description='Full name of the Nimbus customer to look up.'
            required=true)
        public String customerName;
    }

    public class Response {
        @InvocableVariable(label='Found' description='Whether a matching account was found.')
        public Boolean found;

        @InvocableVariable(label='Summary' description='Human-readable billing summary for the agent to relay.')
        public String summary;

        @InvocableVariable(label='Outstanding Balance' description='Total unpaid amount.')
        public Decimal outstandingBalance;

        @InvocableVariable(label='Open Invoice Count' description='Number of unpaid invoices.')
        public Integer openInvoiceCount;
    }

    @InvocableMethod(
        label='Get Nimbus Billing Summary'
        description='Looks up a Nimbus customer by name and returns their outstanding balance and unpaid invoice details.')
    public static List<Response> getBillingSummary(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            responses.add(buildSummary(req.customerName));
        }
        return responses;
    }

    private static Response buildSummary(String customerName) {
        Response res = new Response();
        res.found = false;
        res.outstandingBalance = 0;
        res.openInvoiceCount = 0;

        if (String.isBlank(customerName)) {
            res.summary = 'No customer name was provided.';
            return res;
        }

        List<Nimbus_Account__c> accounts = [
            SELECT Id, Customer_Name__c, Tier__c
            FROM Nimbus_Account__c
            WHERE Customer_Name__c = :customerName.trim()
            LIMIT 2
        ];

        if (accounts.isEmpty()) {
            res.summary = 'No Nimbus account was found for "' + customerName + '".';
            return res;
        }
        if (accounts.size() > 1) {
            res.summary = 'Multiple Nimbus accounts match "' + customerName +
                '". Please confirm additional details before proceeding.';
            return res;
        }

        Nimbus_Account__c acct = accounts[0];
        res.found = true;

        List<Nimbus_Invoice__c> unpaid = [
            SELECT Name, Amount__c, Due_Date__c, Status__c
            FROM Nimbus_Invoice__c
            WHERE Nimbus_Account__c = :acct.Id AND Status__c != 'Paid'
            ORDER BY Due_Date__c ASC
        ];

        Decimal total = 0;
        for (Nimbus_Invoice__c inv : unpaid) {
            total += (inv.Amount__c == null ? 0 : inv.Amount__c);
        }
        res.outstandingBalance = total;
        res.openInvoiceCount = unpaid.size();

        if (unpaid.isEmpty()) {
            res.summary = acct.Customer_Name__c + ' (' + acct.Tier__c +
                ' tier) has no outstanding balance. All invoices are paid.';
        } else {
            res.summary = acct.Customer_Name__c + ' (' + acct.Tier__c +
                ' tier) has an outstanding balance of ' +
                total.setScale(2).format() + ' across ' + unpaid.size() +
                ' unpaid invoice(s). ' + describeInvoices(unpaid);
        }
        return res;
    }

    private static String describeInvoices(List<Nimbus_Invoice__c> invoices) {
        List<String> parts = new List<String>();
        for (Nimbus_Invoice__c inv : invoices) {
            parts.add(inv.Name + ': ' + inv.Amount__c.setScale(2).format() +
                ' due ' + inv.Due_Date__c.format() + ' (' + inv.Status__c + ')');
        }
        return String.join(parts, '; ') + '.';
    }
}