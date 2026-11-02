"""Read-only: print vehicle list, realtime status and GPS for each car."""

import asyncio
import json

from dotenv import load_dotenv
from pybyd import BydClient, BydConfig


def dump(model) -> str:
    data = model.model_dump(exclude_none=True) if hasattr(model, "model_dump") else model
    return json.dumps(data, indent=2, default=str, ensure_ascii=False)


async def main() -> None:
    load_dotenv()
    config = BydConfig.from_env()

    async with BydClient(config) as client:
        vehicles = await client.get_vehicles()
        print(f"Found {len(vehicles)} vehicle(s)\n")

        for vehicle in vehicles:
            print("=== Vehicle ===")
            print(dump(vehicle))

            print("\n=== Realtime ===")
            print(dump(await client.get_vehicle_realtime(vehicle.vin)))

            print("\n=== GPS ===")
            print(dump(await client.get_gps_info(vehicle.vin)))
            print()


asyncio.run(main())
