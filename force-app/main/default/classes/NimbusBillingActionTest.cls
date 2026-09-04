@isTest
private class NimbusBillingActionTest {

    @TestSetup
    static void setup() {
        Nimbus_Account__c withBalance = new Nimbus_Account__c(
            Customer_Name__c = 'Test Balance', Tier__c = 'Premium');
        Nimbus_Account__c allPaid = new Nimbus_Account__c(
            Customer_Name__c = 'Test Paid', Tier__c = 'Standard');
        insert new List<Nimbus_Account__c>{ withBalance, allPaid };

        insert new List<Nimbus_Invoice__c>{
            new Nimbus_Invoice__c(Nimbus_Account__c = withBalance.Id,
                Amount__c = 100.00, Due_Date__c = Date.today().addDays(10), Status__c = 'Open'),
            new Nimbus_Invoice__c(Nimbus_Account__c = withBalance.Id,
                Amount__c = 50.50, Due_Date__c = Date.today().addDays(-5), Status__c = 'Overdue'),
            new Nimbus_Invoice__c(Nimbus_Account__c = withBalance.Id,
                Amount__c = 999.00, Due_Date__c = Date.today().addDays(-30), Status__c = 'Paid'),
            new Nimbus_Invoice__c(Nimbus_Account__c = allPaid.Id,
                Amount__c = 75.00, Due_Date__c = Date.today().addDays(-10), Status__c = 'Paid')
        };
    }

    private static NimbusBillingAction.Response invoke(String name) {
        NimbusBillingAction.Request req = new NimbusBillingAction.Request();
        req.customerName = name;
        return NimbusBillingAction.getBillingSummary(
            new List<NimbusBillingAction.Request>{ req })[0];
    }

    @isTest
    static void outstandingBalanceExcludesPaid() {
        Test.startTest();
        NimbusBillingAction.Response res = invoke('Test Balance');
        Test.stopTest();
        System.assertEquals(true, res.found, 'Account should be found');
        System.assertEquals(150.50, res.outstandingBalance, 'Paid invoice must be excluded');
        System.assertEquals(2, res.openInvoiceCount, 'Only unpaid invoices count');
    }

    @isTest
    static void allPaidReturnsZero() {
        NimbusBillingAction.Response res = invoke('Test Paid');
        System.assertEquals(true, res.found);
        System.assertEquals(0, res.outstandingBalance);
        System.assertEquals(0, res.openInvoiceCount);
        System.assert(res.summary.contains('no outstanding balance'), 'Summary should note zero balance');
    }

    @isTest
    static void notFoundReturnsFalse() {
        NimbusBillingAction.Response res = invoke('Nobody Here');
        System.assertEquals(false, res.found);
        System.assertEquals(0, res.outstandingBalance);
    }

    @isTest
    static void blankNameHandled() {
        NimbusBillingAction.Response res = invoke('   ');
        System.assertEquals(false, res.found, 'Blank name should not match');
    }
}