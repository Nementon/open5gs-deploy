const fs = require('fs');
const path = require('path');
const { MongoClient } = require('mongodb');

async function main() {
    const dbUri = process.env.DB_URI || 'mongodb://mongodb:27017/open5gs';
    const mcc = process.env.MCC || '999';
    const mnc = process.env.MNC || '70';
    const sst = parseInt(process.env.SST || '1', 10);
    const sd = process.env.SD || 'ffffff';

    console.log(`[Provision] Connecting to MongoDB at: ${dbUri}`);
    const client = new MongoClient(dbUri, { serverSelectionTimeoutMS: 30000 });

    try {
        await client.connect();
        const db = client.db();
        const collection = db.collection('subscribers');

        const configPath = '/open5gs/config/subscribers.json';
        let subscribersToProvision = [];

        let isFile = false;
        try {
            if (fs.existsSync(configPath) && fs.lstatSync(configPath).isFile()) {
                isFile = true;
            }
        } catch (e) {}

        if (isFile) {
            console.log(`[Provision] Loading subscriber configurations from ${configPath}`);
            const fileData = fs.readFileSync(configPath, 'utf8');
            const parsed = JSON.parse(fileData);
            subscribersToProvision = Array.isArray(parsed) ? parsed : [parsed];
        } else {
            console.log('[Provision] No valid subscribers.json found. Provisioning default subscriber...');
	    let imsi = `${mcc}${mnc}000000001`;
	    if (imsi.length == 14) {
	      imsi = `${mcc}${mnc}0000000001`;
	    }
            subscribersToProvision = [
                {
                    imsi: imsi,
                    subscribed_rau_tau_timer: 12,
                    subscriber_status: 0,
                    access_restriction_data: 32,
                    security: {
                        k: '465B5CE8B199B49FAA5F0A2EE238A6BC',
                        amf: '8000',
                        opc: 'E8ED289DEBA952E4283B54E88E6183CA'
                    },
                    ambr: {
                        uplink: { value: 1, unit: 3 }, // 1 Gbps
                        downlink: { value: 1, unit: 3 }
                    },
                    slice: [
                        {
                            sst: sst,
                            sd: sd,
                            default_indicator: true,
                            session: [
                                {
                                    name: 'internet',
                                    type: 3,
                                    pcc_rule: [],
                                    qos: {
                                        index: 9,
                                        arp: {
                                            priority_level: 8,
                                            pre_emption_capability: 1,
                                            pre_emption_vulnerability: 1
                                        }
                                    },
                                    ambr: {
                                        uplink: { value: 1, unit: 3 }, // 1 Gbps
                                        downlink: { value: 1, unit: 3 }
                                    }
                                }
                            ]
                        }
                    ]
                }
            ];
        }

        for (const sub of subscribersToProvision) {
            if (!sub.imsi) {
                console.warn('[Provision] Skipping invalid subscriber entry without IMSI:', sub);
                continue;
            }
            console.log(`[Provision] Provisioning subscriber IMSI: ${sub.imsi}`);
            await collection.replaceOne({ imsi: sub.imsi }, sub, { upsert: true });
        }
        console.log('[Provision] Subscriber provisioning completed successfully.');
    } catch (err) {
        console.error('[Provision] Error during subscriber provisioning:', err);
        process.exit(1);
    } finally {
        await client.close();
    }
}

main();
