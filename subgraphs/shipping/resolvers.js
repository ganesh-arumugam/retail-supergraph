export const resolvers = {
  Order: {
    // Deterministic: result depends only on item weights + shipping address.
    // Math.random() removed so caching is testable — repeated calls with the
    // same representation hash must return the same value.
    shippingCost: (parent) => {
      const variantCost = parent.items.map(it => getCostToShipToAddress(it.weight, parent.buyer.shippingAddress));
      return variantCost.reduce((prev, cur) => prev + cur, 0);
    },
  },
};


// Simulate calculating real shipping costs from an address
// Just turn address string size to a number for simple math
const getCostToShipToAddress = (weight, address) => {
  return weight * address.length;
};
